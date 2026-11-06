import XCTest
@testable import StampSign

/// Известные ответы из RFC 7091 (тестовая кривая 256 бит), числа — big-endian.
final class GOST3410Tests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        return out
    }

    private let curve = GOSTCurveParams(
        size: 32,
        p: "8000000000000000000000000000000000000000000000000000000000000431",
        a: "0000000000000000000000000000000000000000000000000000000000000007",
        b: "5fbff498aa938ce739b8e022fbafef40563f6e6a3472fc2a514c0ce9dae23b7e",
        q: "8000000000000000000000000000000150fe8a1892976154c59cfc193accf5b3",
        x: "0000000000000000000000000000000000000000000000000000000000000002",
        y: "08e2a8a0e65147d4bd6316030e16d19c85c97f0a9ca267122b96abbcea7e8fc8")

    private let pubX = "7f2b49e270db6d90d8595bec458b50c58585ba1d4e9b788f6689dbd8e56fd80b"
    private let pubY = "26f1b489d6701dd185c8413a977b3cbbaf64d1c593d26627dffb101a87ff77da"
    private let digest = "2dfbc1b372d89a1188c09c52e0eec61fce52032ab1022e8e67ece6672b043ee5"
    private let r = "41aa28d2f1ab148280cd9ed56feda41974053554a42767b83ad043fd39dc0493"
    private let s = "01456c64ba4642a1653c235a98a60249bcd6d3f746b631df928014f6c5bf9c40"

    func testValidSignatureVerifies() {
        let ok = GOST3410(curve).verify(px: bytes(pubX), py: bytes(pubY), e: bytes(digest), r: bytes(r), s: bytes(s))
        XCTAssertTrue(ok)
    }

    func testWrongDigestFails() {
        var d = bytes(digest); d[0] ^= 1
        XCTAssertFalse(GOST3410(curve).verify(px: bytes(pubX), py: bytes(pubY), e: d, r: bytes(r), s: bytes(s)))
    }

    func testWrongSignatureFails() {
        var sig = bytes(s); sig[31] ^= 1
        XCTAssertFalse(GOST3410(curve).verify(px: bytes(pubX), py: bytes(pubY), e: bytes(digest), r: bytes(r), s: sig))
    }

    func testZeroSignatureRejected() {
        let zero = [UInt8](repeating: 0, count: 32)
        XCTAssertFalse(GOST3410(curve).verify(px: bytes(pubX), py: bytes(pubY), e: bytes(digest), r: zero, s: zero))
    }

    func testBuiltInCurvesLoad() {
        for (oid, c) in GOSTCurves.byOID {
            XCTAssertTrue(c.size == 32 || c.size == 64, oid)
            XCTAssertEqual(c.p.count, c.size * 2, oid)
        }
        XCTAssertNotNil(GOSTCurves.byOID["1.2.643.2.2.35.1"])  // CryptoPro-A
    }
}
