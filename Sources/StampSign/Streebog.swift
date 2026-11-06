import Foundation

/// ГОСТ Р 34.11-2012 «Стрибог» (RFC 6986), 256 и 512 бит.
enum Streebog {
    typealias W = [UInt64]  // 512 бит = 8 слов (little-endian)

    private static let T = StreebogTables.T
    private static let C: [W] = StreebogTables.C.map { b in
        (0..<8).map { i in (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[i * 8 + $1]) << UInt64(8 * $1) } }
    }

    private static func lps(_ x: W) -> W {
        var out = W(repeating: 0, count: 8)
        for i in 0..<8 {
            var v: UInt64 = 0
            let sh = UInt64(8 * i)
            for j in 0..<8 { v ^= T[j][Int((x[j] >> sh) & 0xff)] }
            out[i] = v
        }
        return out
    }

    private static func xor(_ a: W, _ b: W) -> W {
        var r = a
        for i in 0..<8 { r[i] ^= b[i] }
        return r
    }

    private static func add(_ a: W, _ b: W) -> W {
        var r = W(repeating: 0, count: 8)
        var carry: UInt64 = 0
        for i in 0..<8 {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return r
    }

    private static func g(_ h: W, _ n: W, _ m: W) -> W {
        var k = lps(xor(n, h))
        var st = xor(k, m)
        for i in 0..<12 {
            st = lps(st)
            k = lps(xor(k, C[i]))
            st = xor(st, k)
        }
        return xor(xor(st, h), m)
    }

    private static func words(_ b: UnsafeBufferPointer<UInt8>, _ off: Int) -> W {
        var w = W(repeating: 0, count: 8)
        for i in 0..<8 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[off + i * 8 + k]) << UInt64(8 * k) }
            w[i] = v
        }
        return w
    }

    static func hash(_ data: Data, bits: Int) -> [UInt8] {
        var h = W(repeating: bits == 256 ? 0x0101_0101_0101_0101 : 0, count: 8)
        var n = W(repeating: 0, count: 8)
        var sigma = W(repeating: 0, count: 8)
        let zero = W(repeating: 0, count: 8)
        var v512 = zero; v512[0] = 512

        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var off = 0
            while b.count - off >= 64 {
                let m = words(b, off)
                h = g(h, n, m)
                n = add(n, v512)
                sigma = add(sigma, m)
                off += 64
            }
            let rem = b.count - off
            var pad = [UInt8](repeating: 0, count: 64)
            for i in 0..<rem { pad[i] = b[off + i] }
            pad[rem] = 1
            let m = pad.withUnsafeBufferPointer { words($0, 0) }
            h = g(h, n, m)
            var len = zero; len[0] = UInt64(rem * 8)
            n = add(n, len)
            sigma = add(sigma, m)
            h = g(h, zero, n)
            h = g(h, zero, sigma)
        }
        var out: [UInt8] = []
        for w in h { for k in 0..<8 { out.append(UInt8((w >> UInt64(8 * k)) & 0xff)) } }
        return bits == 256 ? Array(out[32..<64]) : out
    }
}
