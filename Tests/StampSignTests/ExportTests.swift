import CoreGraphics
import XCTest
@testable import StampSign

final class ExportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("StampSignTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makePDF(pages: Int) throws -> URL {
        let url = dir.appendingPathComponent("in.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 50, y: 700, width: 200, height: 40))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private let info = SignatureInfo(
        serialHex: "0123456789ABCDEF", owner: "Иванов Иван Иванович",
        notBefore: Date(timeIntervalSince1970: 1_700_000_000), notAfter: Date(timeIntervalSince1970: 1_800_000_000),
        signingTime: Date(timeIntervalSince1970: 1_750_000_000))

    func testExportWithAttachmentsRoundTrips() throws {
        let src = try makePDF(pages: 2)
        let sig = Data((0..<300).map { UInt8($0 % 251) })
        let out = dir.appendingPathComponent("out.pdf")
        let items = [
            PDFAttachments.Item(role: "Original", name: "Документ.pdf", mime: "application/pdf", data: try Data(contentsOf: src)),
            PDFAttachments.Item(role: "Signature", name: "Документ.pdf.sig", mime: "application/pkcs7-signature", data: sig),
        ]
        try PDFExporter.export(source: src, info: info, placement: Placement(x: 100, y: 20, width: 190),
                               pages: [1], attachments: items, to: out)

        let doc = try XCTUnwrap(CGPDFDocument(out as CFURL))
        XCTAssertEqual(doc.numberOfPages, 2)
        let got = try XCTUnwrap(PDFAttachments.extract(from: try Data(contentsOf: out)))
        XCTAssertEqual(got.document, try Data(contentsOf: src))
        XCTAssertEqual(got.signature, sig)
    }

    func testExportWithoutAttachmentsHasNone() throws {
        let src = try makePDF(pages: 1)
        let out = dir.appendingPathComponent("out.pdf")
        try PDFExporter.export(source: src, info: info, placement: Placement(x: 0, y: 0, width: 190), pages: nil, to: out)
        XCTAssertNil(PDFAttachments.extract(from: try Data(contentsOf: out)))
    }

    func testPlacementKeepsAspectRatio() {
        let p = Placement(x: 0, y: 0, width: 380)
        XCTAssertEqual(p.height, 380 * Double(StampRenderer.designSize.height / StampRenderer.designSize.width), accuracy: 0.001)
    }
}
