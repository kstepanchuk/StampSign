import Foundation

struct VerificationResult {
    enum State { case ok, bad, unsupported, unknown }
    var integrity: State = .unknown      // хеш PDF совпал с messageDigest
    var signature: State = .unknown      // ЭЦП подписанта верна
    var chain: State = .unknown          // подписи сертификатов в цепочке верны
    var validity: State = .unknown       // сертификат действовал в момент подписания
    var chainRoot: String?
    var notes: [String] = []
}

private struct Cert {
    let tbs: TLV
    let issuerRaw: String
    let subjectRaw: String
    let serial: [UInt8]
    let nb: Date?, na: Date?
    let spki: TLV
    let sigAlg: String
    let sigValue: [UInt8]
    let subject: TLV
}

enum SigVerifier {
    /// Порядок байт, найденный эмпирически для CMS/сертификатов ГОСТ (см. --verify-debug).
    struct Conv { var pubLE = true, hashLE = true, sigSR = true, sigLE = false }
    static var conv = Conv()

    // MARK: OID

    private static func oid(_ b: [UInt8]) -> String {
        guard let f = b.first else { return "" }
        var parts = [Int(f) / 40, Int(f) % 40]
        var v = 0
        for x in b.dropFirst() {
            v = (v << 7) | Int(x & 0x7f)
            if x & 0x80 == 0 { parts.append(v); v = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    private static func hashBits(_ oid: String) -> Int? {
        switch oid {
        case "1.2.643.7.1.1.2.2", "1.2.643.7.1.1.3.2": return 256
        case "1.2.643.7.1.1.2.3", "1.2.643.7.1.1.3.3": return 512
        default: return nil
        }
    }

    // MARK: Разбор сертификатов

    /// Имя без учёта порядка RDN (в сертификатах УЦ он нередко отличается).
    private static func nameKey(_ t: TLV, _ der: DER) -> String {
        var items: [String] = []
        for rdn in (try? der.kids(t)) ?? [] {
            for atv in (try? der.kids(rdn)) ?? [] {
                let k = (try? der.kids(atv)) ?? []
                if k.count == 2 { items.append(oid(der.bytes(k[0])) + "=" + der.string(k[1])) }
            }
        }
        return items.sorted().joined(separator: "|")
    }

    private static func parseCert(_ t: TLV, _ der: DER) throws -> Cert {
        let ck = try der.kids(t)
        guard ck.count >= 3 else { throw SigError.invalid("сертификат") }
        let tc = try der.kids(ck[0])
        let o = tc.first?.tag == 0xA0 ? 1 : 0
        guard tc.count >= o + 6 else { throw SigError.invalid("сертификат") }
        let vk = try der.kids(tc[o + 3])
        let sigAlgOID = try der.kids(ck[1]).first.map { oid(der.bytes($0)) } ?? ""
        return Cert(
            tbs: ck[0],
            issuerRaw: nameKey(tc[o + 2], der),
            subjectRaw: nameKey(tc[o + 4], der),
            serial: der.bytes(tc[o]),
            nb: vk.count == 2 ? der.time(vk[0]) : nil,
            na: vk.count == 2 ? der.time(vk[1]) : nil,
            spki: tc[o + 5],
            sigAlg: sigAlgOID,
            sigValue: Array(der.bytes(ck[2]).dropFirst()),
            subject: tc[o + 4])
    }

    private static func commonName(_ c: Cert, _ der: DER) -> String? {
        guard let rdns = try? der.kids(c.subject) else { return nil }
        for rdn in rdns {
            for atv in (try? der.kids(rdn)) ?? [] {
                let k = (try? der.kids(atv)) ?? []
                if k.count == 2, der.bytes(k[0]) == [0x55, 0x04, 0x03] { return der.string(k[1]) }
            }
        }
        return nil
    }

    /// (кривая, x, y) в «сырых» байтах ключа.
    private static func publicKey(_ c: Cert, _ der: DER) -> (GOSTCurveParams, [UInt8])? {
        guard let sk = try? der.kids(c.spki), sk.count == 2,
              let ak = try? der.kids(sk[0]), ak.count >= 2,
              let pk = try? der.kids(ak[1]), let curveOID = pk.first,
              let curve = GOSTCurves.byOID[oid(der.bytes(curveOID))] else { return nil }
        var key = Array(der.bytes(sk[1]).dropFirst())
        if key.first == 0x04, let inner = try? DER(d: key).parse(0, key.count), inner.full.count == key.count {
            key = Array(key[inner.content])
        }
        guard key.count == curve.size * 2 else { return nil }
        return (curve, key)
    }

    // MARK: Проверка

    static func rawVerify(curve: GOSTCurveParams, pub: [UInt8], hash: [UInt8], sig: [UInt8], conv c: Conv) -> Bool {
        let n = curve.size
        guard hash.count == n, sig.count == 2 * n, pub.count == 2 * n else { return false }
        func ord(_ b: ArraySlice<UInt8>, _ le: Bool) -> [UInt8] { le ? Array(b.reversed()) : Array(b) }
        let px = ord(pub[0..<n], c.pubLE), py = ord(pub[n..<2 * n], c.pubLE)
        let e = ord(hash[0..<n], c.hashLE)
        let first = sig[0..<n], second = sig[n..<2 * n]
        let r = ord(c.sigSR ? second : first, c.sigLE)
        let s = ord(c.sigSR ? first : second, c.sigLE)
        return GOST3410(curve).verify(px: px, py: py, e: e, r: r, s: s)
    }

    static func verify(sig: Data, document: Data) -> VerificationResult {
        var res = VerificationResult()
        do { try run(sig: sig, document: document, res: &res) }
        catch { res.notes.append(error.localizedDescription) }
        return res
    }

    private static func run(sig: Data, document: Data, res: inout VerificationResult) throws {
        let raw = [UInt8](sig)
        let der = DER(d: raw)
        let root = try der.parse(0, raw.count)
        let rk = try der.kids(root)
        guard rk.count >= 2, let sd = try der.kids(rk[1]).first else { throw SigError.invalid("это не CMS SignedData") }
        let sdk = try der.kids(sd)
        guard let signerSet = sdk.last, signerSet.tag == 0x31,
              let certsNode = sdk.dropFirst(3).first(where: { $0.tag == 0xA0 }),
              let signer = try der.kids(signerSet).first else { throw SigError.invalid("нет сертификатов или SignerInfo") }
        let sk = try der.kids(signer)
        guard sk.count >= 5 else { throw SigError.invalid("повреждённый SignerInfo") }

        var certs = try der.kids(certsNode).filter { $0.tag == 0x30 }.map { try parseCert($0, der) }
        let signerCerts = certs
        // сертификаты из штампа времени (там обычно лежит сертификат УЦ)
        if let un = sk.dropFirst(2).first(where: { $0.tag == 0xA1 }) {
            for a in (try? der.kids(un)) ?? [] {
                let ak = (try? der.kids(a)) ?? []
                guard ak.count >= 2, der.bytes(ak[0]) == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x02, 0x0E],
                      let token = try? der.kids(ak[1]).first, let wrap = try? der.kids(token).dropFirst().first,
                      let tsd = try? der.kids(wrap).first, let tk = try? der.kids(tsd),
                      let tcerts = tk.dropFirst(3).first(where: { $0.tag == 0xA0 }),
                      let list = try? der.kids(tcerts) else { continue }
                for c in list where c.tag == 0x30 { if let pc = try? parseCert(c, der) { certs.append(pc) } }
            }
        }

        // signer cert
        var signerSerial: [UInt8]?
        if sk[1].tag == 0x30, let ik = try? der.kids(sk[1]), ik.count >= 2 { signerSerial = der.bytes(ik[1]) }
        guard let cert = signerCerts.first(where: { signerSerial == nil || $0.serial == signerSerial }) else {
            throw SigError.invalid("сертификат подписанта не найден")
        }

        let digestOID = try der.kids(sk[2]).first.map { oid(der.bytes($0)) } ?? ""
        guard let bits = hashBits(digestOID) else {
            res.integrity = .unsupported; res.signature = .unsupported
            res.notes.append("Алгоритм хеширования \(digestOID) не поддерживается (нужен Стрибог).")
            return
        }
        let attrsIdx = sk[3].tag == 0xA0 ? 3 : -1
        guard attrsIdx >= 0, sk.count >= 6 else { throw SigError.invalid("нет подписанных атрибутов") }
        let signature = der.bytes(sk[5])
        let attrs = sk[attrsIdx]

        // 1. messageDigest
        var messageDigest: [UInt8]?
        for a in try der.kids(attrs) {
            let ak = try der.kids(a)
            if ak.count >= 2, der.bytes(ak[0]) == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04],
               let v = try der.kids(ak[1]).first { messageDigest = der.bytes(v) }
        }
        let docHash = Streebog.hash(document, bits: bits)
        if let md = messageDigest { res.integrity = md == docHash ? .ok : .bad }

        // 2. подпись над DER(signedAttrs) с тегом SET
        var attrsDER = Array(raw[attrs.full])
        attrsDER[0] = 0x31
        let h = Streebog.hash(Data(attrsDER), bits: bits)
        if let (curve, pub) = publicKey(cert, der) {
            if curve.size * 8 == bits {
                res.signature = rawVerify(curve: curve, pub: pub, hash: h, sig: signature, conv: conv) ? .ok : .bad
            } else {
                res.signature = .unsupported
                res.notes.append("Размер ключа не совпадает с хешем.")
            }
        } else {
            res.signature = .unsupported
            res.notes.append("Кривая ключа сертификата не поддерживается.")
        }

        // 3. срок действия
        if let t = try? Self.signingTimeFor(sk, der), let nb = cert.nb, let na = cert.na {
            res.validity = (t >= nb && t <= na) ? .ok : .bad
        }

        // 4. цепочка внутри .sig
        var cur = cert
        var depth = 0
        while depth < 6 {
            depth += 1
            let cands = certs.filter { $0.subjectRaw == cur.issuerRaw && $0.serial != cur.serial }
            guard !cands.isEmpty else {
                if depth == 1 {
                    res.chain = .unknown
                    res.notes.append("Сертификат УЦ отсутствует в .sig, цепочку не проверить.")
                }
                return
            }
            guard let cb = hashBits(cur.sigAlg) else { res.chain = .unsupported; return }
            let tbsHash = Streebog.hash(Data(raw[cur.tbs.full]), bits: cb)
            var verified: Cert?
            for c in cands {
                if let (curve, pub) = publicKey(c, der), curve.size * 8 == cb,
                   rawVerify(curve: curve, pub: pub, hash: tbsHash, sig: cur.sigValue, conv: conv) {
                    verified = c; break
                }
            }
            guard let iss = verified else {
                if depth == 1 {
                    res.chain = .unknown
                    res.notes.append("В .sig нет сертификата УЦ с ключом, которым выдан сертификат подписанта.")
                }
                return
            }
            res.chain = .ok
            res.chainRoot = commonName(iss, der)
            if iss.subjectRaw == iss.issuerRaw { return }  // самоподписанный корень
            cur = iss
        }
    }

    private static func signingTimeFor(_ sk: [TLV], _ der: DER) throws -> Date? {
        guard let attrs = sk.dropFirst(2).first(where: { $0.tag == 0xA0 }) else { return nil }
        for a in try der.kids(attrs) {
            let ak = try der.kids(a)
            if ak.count >= 2, der.bytes(ak[0]) == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05],
               let v = try der.kids(ak[1]).first { return der.time(v) }
        }
        return nil
    }

    // MARK: Отладка порядка байт

    static func debugConventions(sig: Data) {
        let raw = [UInt8](sig)
        let der = DER(d: raw)
        guard let root = try? der.parse(0, raw.count), let rk = try? der.kids(root),
              let sd = try? der.kids(rk[1]).first, let sdk = try? der.kids(sd),
              let signerSet = sdk.last, let signer = try? der.kids(signerSet).first,
              let sk = try? der.kids(signer), let certsNode = sdk.dropFirst(3).first(where: { $0.tag == 0xA0 }),
              let certs = try? der.kids(certsNode).filter({ $0.tag == 0x30 }).map({ try parseCert($0, der) })
        else { print("parse fail"); return }
        var serial: [UInt8]?
        if let ik = try? der.kids(sk[1]), ik.count >= 2 { serial = der.bytes(ik[1]) }
        guard let cert = certs.first(where: { $0.serial == serial }), let (curve, pub) = publicKey(cert, der) else { print("no key"); return }
        var attrsDER = Array(raw[sk[3].full]); attrsDER[0] = 0x31
        let h = Streebog.hash(Data(attrsDER), bits: 256)
        let signature = der.bytes(sk[5])
        print("curve size \(curve.size), sig \(signature.count) bytes, pub \(pub.count) bytes")
        for bits in 0..<16 {
            let c = Conv(pubLE: bits & 1 != 0, hashLE: bits & 2 != 0, sigSR: bits & 4 != 0, sigLE: bits & 8 != 0)
            let ok = rawVerify(curve: curve, pub: pub, hash: h, sig: signature, conv: c)
            print(c, ok ? "OK <<<<" : "-")
        }
    }
}
