import Foundation

typealias Limbs = [UInt64]

func limbs(beBytes b: [UInt8], count n: Int) -> Limbs {
    var r = Limbs(repeating: 0, count: n)
    for (i, byte) in b.reversed().enumerated() where i / 8 < n { r[i / 8] |= UInt64(byte) << UInt64(8 * (i % 8)) }
    return r
}

func limbs(hex: String, count n: Int) -> Limbs {
    var bytes: [UInt8] = []
    var it = hex.makeIterator()
    while let a = it.next(), let b = it.next() { bytes.append(UInt8(String([a, b]), radix: 16) ?? 0) }
    return limbs(beBytes: bytes, count: n)
}

func cmp(_ a: Limbs, _ b: Limbs) -> Int {
    for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
    return 0
}

func isZero(_ a: Limbs) -> Bool { !a.contains { $0 != 0 } }

private func rawAdd(_ a: Limbs, _ b: Limbs) -> (Limbs, Bool) {
    var r = a
    var carry: UInt64 = 0
    for i in 0..<a.count {
        let (s1, o1) = a[i].addingReportingOverflow(b[i])
        let (s2, o2) = s1.addingReportingOverflow(carry)
        r[i] = s2
        carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
    }
    return (r, carry != 0)
}

private func rawSub(_ a: Limbs, _ b: Limbs) -> (Limbs, Bool) {
    var r = a
    var borrow: UInt64 = 0
    for i in 0..<a.count {
        let (s1, o1) = a[i].subtractingReportingOverflow(b[i])
        let (s2, o2) = s1.subtractingReportingOverflow(borrow)
        r[i] = s2
        borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
    }
    return (r, borrow != 0)
}

/// Арифметика по модулю нечётного m в форме Монтгомери.
struct Field {
    let n: Int
    let m: Limbs
    let n0: UInt64
    let r2: Limbs
    let one: Limbs  // R mod m
    let zero: Limbs

    init(modulus: Limbs) {
        n = modulus.count
        m = modulus
        zero = Limbs(repeating: 0, count: modulus.count)
        var x = modulus[0]
        for _ in 0..<6 { x = x &* (2 &- modulus[0] &* x) }
        n0 = 0 &- x
        func addMod(_ a: Limbs, _ b: Limbs) -> Limbs {
            let (s, c) = rawAdd(a, b)
            return (c || cmp(s, modulus) >= 0) ? rawSub(s, modulus).0 : s
        }
        var v = zero; v[0] = 1
        for _ in 0..<(64 * modulus.count) { v = addMod(v, v) }
        one = v
        for _ in 0..<(64 * modulus.count) { v = addMod(v, v) }
        r2 = v
    }

    func add(_ a: Limbs, _ b: Limbs) -> Limbs {
        let (s, c) = rawAdd(a, b)
        return (c || cmp(s, m) >= 0) ? rawSub(s, m).0 : s
    }

    func sub(_ a: Limbs, _ b: Limbs) -> Limbs {
        let (d, br) = rawSub(a, b)
        return br ? rawAdd(d, m).0 : d
    }

    func mul(_ a: Limbs, _ b: Limbs) -> Limbs {
        var t = [UInt64](repeating: 0, count: n + 2)
        for i in 0..<n {
            var c: UInt64 = 0
            let bi = b[i]
            for j in 0..<n {
                let (hi, lo) = a[j].multipliedFullWidth(by: bi)
                let (s1, o1) = t[j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(c)
                t[j] = s2
                c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            let (s, o) = t[n].addingReportingOverflow(c)
            t[n] = s
            t[n + 1] = o ? 1 : 0
            let mq = t[0] &* n0
            let (hi0, lo0) = mq.multipliedFullWidth(by: m[0])
            let (_, o0) = t[0].addingReportingOverflow(lo0)
            c = hi0 &+ (o0 ? 1 : 0)
            for j in 1..<n {
                let (hi, lo) = mq.multipliedFullWidth(by: m[j])
                let (s1, o1) = t[j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(c)
                t[j - 1] = s2
                c = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            let (s3, o3) = t[n].addingReportingOverflow(c)
            t[n - 1] = s3
            t[n] = t[n + 1] &+ (o3 ? 1 : 0)
        }
        var r = Array(t[0..<n])
        if t[n] != 0 || cmp(r, m) >= 0 { r = rawSub(r, m).0 }
        return r
    }

    func toMont(_ a: Limbs) -> Limbs { mul(a, r2) }
    func fromMont(_ a: Limbs) -> Limbs { var o = zero; o[0] = 1; return mul(a, o) }

    func pow(_ a: Limbs, _ e: Limbs) -> Limbs {
        var r = one
        for i in stride(from: e.count * 64 - 1, through: 0, by: -1) {
            r = mul(r, r)
            if (e[i / 64] >> UInt64(i % 64)) & 1 == 1 { r = mul(r, a) }
        }
        return r
    }

    func inv(_ a: Limbs) -> Limbs {
        var two = zero; two[0] = 2
        return pow(a, rawSub(m, two).0)
    }
}

struct ECPoint { var x, y, z: Limbs }

struct GOST3410 {
    let n: Int
    let fp: Field
    let fq: Field
    let a: Limbs
    let gx, gy: Limbs
    let q: Limbs
    let p: Limbs

    init(_ c: GOSTCurveParams) {
        n = c.size / 8
        p = limbs(hex: c.p, count: n)
        q = limbs(hex: c.q, count: n)
        fp = Field(modulus: p)
        fq = Field(modulus: q)
        a = fp.toMont(limbs(hex: c.a, count: n))
        gx = fp.toMont(limbs(hex: c.x, count: n))
        gy = fp.toMont(limbs(hex: c.y, count: n))
    }

    private var infinity: ECPoint { ECPoint(x: fp.one, y: fp.one, z: fp.zero) }

    private func dbl(_ P: ECPoint) -> ECPoint {
        if isZero(P.z) || isZero(P.y) { return infinity }
        let yy = fp.mul(P.y, P.y)
        var s = fp.mul(P.x, yy); s = fp.add(s, s); s = fp.add(s, s)
        let xx = fp.mul(P.x, P.x)
        let zz = fp.mul(P.z, P.z)
        var m = fp.add(fp.add(xx, xx), xx)
        m = fp.add(m, fp.mul(a, fp.mul(zz, zz)))
        let x3 = fp.sub(fp.mul(m, m), fp.add(s, s))
        var y4 = fp.mul(yy, yy); y4 = fp.add(y4, y4); y4 = fp.add(y4, y4); y4 = fp.add(y4, y4)
        let y3 = fp.sub(fp.mul(m, fp.sub(s, x3)), y4)
        let yz = fp.mul(P.y, P.z)
        return ECPoint(x: x3, y: y3, z: fp.add(yz, yz))
    }

    private func add(_ P: ECPoint, _ Q: ECPoint) -> ECPoint {
        if isZero(P.z) { return Q }
        if isZero(Q.z) { return P }
        let z1z1 = fp.mul(P.z, P.z), z2z2 = fp.mul(Q.z, Q.z)
        let u1 = fp.mul(P.x, z2z2), u2 = fp.mul(Q.x, z1z1)
        let s1 = fp.mul(P.y, fp.mul(Q.z, z2z2)), s2 = fp.mul(Q.y, fp.mul(P.z, z1z1))
        if cmp(u1, u2) == 0 { return cmp(s1, s2) == 0 ? dbl(P) : infinity }
        let h = fp.sub(u2, u1), r = fp.sub(s2, s1)
        let hh = fp.mul(h, h), hhh = fp.mul(h, hh)
        let v = fp.mul(u1, hh)
        let x3 = fp.sub(fp.sub(fp.mul(r, r), hhh), fp.add(v, v))
        let y3 = fp.sub(fp.mul(r, fp.sub(v, x3)), fp.mul(s1, hhh))
        return ECPoint(x: x3, y: y3, z: fp.mul(h, fp.mul(P.z, Q.z)))
    }

    private func mul(_ k: Limbs, _ P: ECPoint) -> ECPoint {
        var R = infinity
        for i in stride(from: k.count * 64 - 1, through: 0, by: -1) {
            R = dbl(R)
            if (k[i / 64] >> UInt64(i % 64)) & 1 == 1 { R = add(R, P) }
        }
        return R
    }

    /// Все числа — big-endian байты длиной size.
    func verify(px: [UInt8], py: [UInt8], e eBytes: [UInt8], r rBytes: [UInt8], s sBytes: [UInt8]) -> Bool {
        let r = limbs(beBytes: rBytes, count: n), s = limbs(beBytes: sBytes, count: n)
        guard !isZero(r), cmp(r, q) < 0, !isZero(s), cmp(s, q) < 0 else { return false }
        var e = limbs(beBytes: eBytes, count: n)
        while cmp(e, q) >= 0 { e = rawSub(e, q).0 }
        if isZero(e) { e = fq.zero; e[0] = 1 }
        let v = fq.inv(fq.toMont(e))
        let z1 = fq.fromMont(fq.mul(fq.toMont(s), v))
        let z2 = fq.fromMont(fq.sub(fq.zero, fq.mul(fq.toMont(r), v)))
        let pub = ECPoint(x: fp.toMont(limbs(beBytes: px, count: n)), y: fp.toMont(limbs(beBytes: py, count: n)), z: fp.one)
        let G = ECPoint(x: gx, y: gy, z: fp.one)
        let C = add(mul(z1, G), mul(z2, pub))
        guard !isZero(C.z) else { return false }
        let zi = fp.inv(C.z)
        var xr = fp.fromMont(fp.mul(C.x, fp.mul(zi, zi)))
        while cmp(xr, q) >= 0 { xr = rawSub(xr, q).0 }
        return cmp(xr, r) == 0
    }
}
