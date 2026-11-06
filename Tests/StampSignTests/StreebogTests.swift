import XCTest
@testable import StampSign

final class StreebogTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// Тестовое сообщение M1 из RFC 6986 (63 байта).
    private let m1 = Data("012345678901234567890123456789012345678901234567890123456789012".utf8)

    func testStreebog256() {
        XCTAssertEqual(hex(Streebog.hash(m1, bits: 256)),
                       "9d151eefd8590b89daa6ba6cb74af9275dd051026bb149a452fd84e5e57b5500")
    }

    func testStreebog512() {
        XCTAssertEqual(hex(Streebog.hash(m1, bits: 512)),
                       "1b54d01a4af5b9d5cc3d86d68d285462b19abc2475222f35c085122be4ba1ffa"
                       + "00ad30f8767b3a82384c6574f024c311e2a481332b08ef7f41797891c1646f48")
    }

    func testMultiBlockMessageIsDeterministicAndLengthSensitive() {
        let a = Streebog.hash(Data(repeating: 0x61, count: 200), bits: 256)
        let b = Streebog.hash(Data(repeating: 0x61, count: 200), bits: 256)
        let c = Streebog.hash(Data(repeating: 0x61, count: 201), bits: 256)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, 32)
    }
}
