import CoreGraphics
import Foundation

struct Placement: Equatable {
    /// Левый нижний угол штампа и ширина — в pt, origin — левый нижний угол страницы (как её видит пользователь).
    var x: Double
    var y: Double
    var width: Double
    var height: Double { width * Double(StampRenderer.designSize.height / StampRenderer.designSize.width) }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum ExportError: LocalizedError {
    case open, create
    var errorDescription: String? {
        switch self {
        case .open: return "Не удалось открыть PDF (возможно, он зашифрован)."
        case .create: return "Не удалось создать выходной PDF."
        }
    }
}

enum PDFExporter {
    static func displaySize(_ page: CGPDFPage) -> CGSize {
        let b = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    static func pageCount(_ url: URL) -> Int { CGPDFDocument(url as CFURL)?.numberOfPages ?? 0 }

    static func firstPageSize(_ url: URL, page: Int) -> CGSize? {
        CGPDFDocument(url as CFURL)?.page(at: page + 1).map(displaySize)
    }

    /// pages — индексы (с 0), nil = все страницы.
    static func export(source: URL, info: SignatureInfo, placement: Placement, pages: Set<Int>?,
                       attachments: [PDFAttachments.Item] = [], to dest: URL) throws {
        guard let doc = CGPDFDocument(source as CFURL), !doc.isEncrypted || doc.unlockWithPassword("") else { throw ExportError.open }
        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ExportError.create }
        for i in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: i) else { continue }
            var box = CGRect(origin: .zero, size: displaySize(page))
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            if pages == nil || pages!.contains(i - 1) {
                StampRenderer.draw(info, in: ctx, rect: placement.rect)
            }
            ctx.endPage()
        }
        ctx.closePDF()
        var out = buffer as Data
        if !attachments.isEmpty { out = try PDFAttachments.append(to: out, items: attachments) }
        try out.write(to: dest, options: .atomic)
    }
}
