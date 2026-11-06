import Foundation

struct SignatureInfo: Equatable {
    var serialHex: String
    var owner: String
    var notBefore: Date
    var notAfter: Date
    var signingTime: Date?
}

enum SigError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let s): return "Не удалось разобрать .sig: \(s)"
        }
    }
}

struct TLV {
    let tag: UInt8
    let content: Range<Int>
    let full: Range<Int>
}

struct DER {
    let d: [UInt8]

    func parse(_ i: Int, _ limit: Int) throws -> TLV {
        guard i + 2 <= limit else { throw SigError.invalid("обрыв данных") }
        let tag = d[i]
        var p = i + 2
        let l0 = Int(d[i + 1])
        if l0 == 0x80 {  // BER indefinite length
            guard tag & 0x20 != 0 else { throw SigError.invalid("неверная длина") }
            var q = p
            while true {
                guard q + 2 <= limit else { throw SigError.invalid("обрыв данных") }
                if d[q] == 0 && d[q + 1] == 0 {
                    return TLV(tag: tag, content: p..<q, full: i..<(q + 2))
                }
                q = try parse(q, limit).full.upperBound
            }
        }
        var len = l0
        if l0 & 0x80 != 0 {
            let n = l0 & 0x7F
            guard n > 0, n <= 4, p + n <= limit else { throw SigError.invalid("неверная длина") }
            len = 0
            for k in 0..<n { len = (len << 8) | Int(d[p + k]) }
            p += n
        }
        guard len >= 0, p + len <= limit else { throw SigError.invalid("обрыв данных") }
        return TLV(tag: tag, content: p..<(p + len), full: i..<(p + len))
    }

    func kids(_ t: TLV) throws -> [TLV] {
        var res: [TLV] = []
        var i = t.content.lowerBound
        while i < t.content.upperBound {
            let c = try parse(i, t.content.upperBound)
            res.append(c)
            i = c.full.upperBound
        }
        return res
    }

    func bytes(_ t: TLV) -> [UInt8] { Array(d[t.content]) }

    func string(_ t: TLV) -> String {
        let b = bytes(t)
        switch t.tag {
        case 0x1E: return String(data: Data(b), encoding: .utf16BigEndian) ?? ""
        case 0x14: return String(data: Data(b), encoding: .isoLatin1) ?? ""
        default: return String(decoding: b, as: UTF8.self)
        }
    }

    func time(_ t: TLV) -> Date? {
        let s = String(decoding: bytes(t), as: UTF8.self)
        var str = String(s.prefix { $0.isASCII && $0.isNumber })
        if t.tag == 0x17 {
            guard str.count >= 10, let yy = Int(str.prefix(2)) else { return nil }
            str = (yy < 50 ? "20" : "19") + str
        }
        if str.count == 12 { str += "00" }
        guard str.count >= 14 else { return nil }
        let n = Array(str.utf8).map { Int($0) - 48 }
        func num(_ a: Int, _ b: Int) -> Int { n[a..<b].reduce(0) { $0 * 10 + $1 } }
        var c = DateComponents()
        c.year = num(0, 4); c.month = num(4, 6); c.day = num(6, 8)
        c.hour = num(8, 10); c.minute = num(10, 12); c.second = num(12, 14)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)
    }
}

enum SigParser {
    private static let oidSigningTime: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05]
    private static let oidCN: [UInt8] = [0x55, 0x04, 0x03]
    private static let oidSurname: [UInt8] = [0x55, 0x04, 0x04]
    private static let oidGiven: [UInt8] = [0x55, 0x04, 0x2A]

    private static let oidTimestampToken: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x02, 0x0E]

    private static func genTime(_ token: TLV, _ der: DER) throws -> Date? {
        guard let sdWrap = try der.kids(token).dropFirst().first, let sd = try der.kids(sdWrap).first else { return nil }
        let k = try der.kids(sd)
        guard k.count >= 3, let wrap = try der.kids(k[2]).dropFirst().first,
              let octet = try der.kids(wrap).first else { return nil }
        let inner = DER(d: der.bytes(octet))
        let root = try inner.parse(0, inner.d.count)
        let f = try inner.kids(root)
        guard f.count >= 5, f[4].tag == 0x18 else { return nil }
        return inner.time(f[4])
    }

    static func parse(_ data: Data) throws -> SignatureInfo {
        var raw = [UInt8](data)
        if let s = String(data: data, encoding: .utf8), s.contains("-----BEGIN") {
            let b64 = s.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
            if let dec = Data(base64Encoded: b64) { raw = [UInt8](dec) }
        }
        let der = DER(d: raw)
        let root = try der.parse(0, raw.count)
        let rk = try der.kids(root)
        guard rk.count >= 2, rk[1].tag == 0xA0, let sd = try der.kids(rk[1]).first else {
            throw SigError.invalid("это не CMS SignedData")
        }
        let sdk = try der.kids(sd)
        guard sdk.count >= 4, let signerSet = sdk.last, signerSet.tag == 0x31,
              let certsNode = sdk.dropFirst(3).first(where: { $0.tag == 0xA0 })
        else { throw SigError.invalid("в подписи нет сертификата или SignerInfo") }

        guard let signer = try der.kids(signerSet).first else { throw SigError.invalid("нет SignerInfo") }
        let sk = try der.kids(signer)
        guard sk.count >= 2 else { throw SigError.invalid("повреждённый SignerInfo") }

        // serial подписанта
        var signerSerial: [UInt8]?
        if sk[1].tag == 0x30 {
            let ik = try der.kids(sk[1])
            if ik.count >= 2 { signerSerial = der.bytes(ik[1]) }
        }

        // signingTime
        var signingTime: Date?
        if let attrs = sk.dropFirst(2).first(where: { $0.tag == 0xA0 }) {
            for a in try der.kids(attrs) {
                let ak = try der.kids(a)
                if ak.count >= 2, der.bytes(ak[0]) == oidSigningTime,
                   let v = try der.kids(ak[1]).first {
                    signingTime = der.time(v)
                }
            }
        }

        // время из штампа времени (TSTInfo.genTime) — как в образце штампа; иначе signingTime
        if let un = sk.dropFirst(2).first(where: { $0.tag == 0xA1 }) {
            for a in try der.kids(un) {
                let ak = try der.kids(a)
                if ak.count >= 2, der.bytes(ak[0]) == oidTimestampToken,
                   let token = try der.kids(ak[1]).first,
                   let t = try? genTime(token, der) {
                    signingTime = t
                }
            }
        }

        // сертификат
        var found: (serial: [UInt8], nb: Date, na: Date, subject: TLV)?
        for cert in try der.kids(certsNode) where cert.tag == 0x30 {
            guard let tbs = try der.kids(cert).first else { continue }
            let tc = try der.kids(tbs)
            let o = (tc.first?.tag == 0xA0) ? 1 : 0
            guard tc.count >= o + 5 else { continue }
            let serial = der.bytes(tc[o])
            let vk = try der.kids(tc[o + 3])
            guard vk.count == 2, let nb = der.time(vk[0]), let na = der.time(vk[1]) else { continue }
            let entry = (serial, nb, na, tc[o + 4])
            if let s = signerSerial {
                if s == serial { found = entry; break }
            } else if found == nil {
                found = entry
            }
        }
        guard let f = found else { throw SigError.invalid("сертификат подписанта не найден в .sig") }

        var attrs: [[UInt8]: String] = [:]
        for rdn in try der.kids(f.subject) {
            for atv in try der.kids(rdn) {
                let k = try der.kids(atv)
                if k.count == 2 { attrs[der.bytes(k[0])] = der.string(k[1]) }
            }
        }
        var owner = ""
        if let sn = attrs[oidSurname], let gn = attrs[oidGiven] {
            owner = "\(sn) \(gn)"
        } else {
            owner = attrs[oidCN] ?? attrs[oidSurname] ?? ""
        }

        var sb = f.serial
        while sb.count > 1, sb[0] == 0, sb[1] >= 0x80 { sb.removeFirst() }
        let hex = sb.map { String(format: "%02X", $0) }.joined()

        return SignatureInfo(serialHex: hex, owner: owner, notBefore: f.nb, notAfter: f.na, signingTime: signingTime)
    }
}
