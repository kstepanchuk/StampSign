import XCTest
@testable import StampSign

final class SigParserTests: XCTestCase {
    func testGarbageThrows() {
        XCTAssertThrowsError(try SigParser.parse(Data([1, 2, 3])))
        XCTAssertThrowsError(try SigParser.parse(Data()))
    }

    func testTruncatedDERThrows() {
        // SEQUENCE длиной 100 байт, но данных нет
        XCTAssertThrowsError(try SigParser.parse(Data([0x30, 0x64, 0x06, 0x01])))
    }

    func testNotSignedDataThrows() {
        // SEQUENCE { INTEGER 1, INTEGER 2 }
        XCTAssertThrowsError(try SigParser.parse(Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02])))
    }

    func testVerifierReportsErrorInsteadOfCrashing() {
        let r = SigVerifier.verify(sig: Data([0x30, 0x00]), document: Data("x".utf8))
        XCTAssertEqual(r.integrity, .unknown)
        XCTAssertEqual(r.signature, .unknown)
        XCTAssertFalse(r.notes.isEmpty)
    }
}
