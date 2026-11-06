import AppKit
import CoreGraphics
import CoreText

enum StampRenderer {
    /// Базовый размер штампа в pt (как в образце: ~190×54).
    static let designSize = CGSize(width: 190, height: 55)
    static let color = CGColor(red: 0.298, green: 0.251, blue: 0.824, alpha: 1)

    /// Часовой пояс отображаемых дат (по умолчанию МСК, как в образце).
    nonisolated(unsafe) static var timeZone = TimeZone(identifier: "Europe/Moscow")!

    static func format(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f.string(from: d)
    }

    static func lines(_ i: SignatureInfo) -> [String] {
        [
            "Сертификат \(i.serialHex)",
            "Владелец \(i.owner)",
            "Действителен с \(format(i.notBefore)) по \(format(i.notAfter))",
            "Дата и время подписания \(format(i.signingTime))",
        ]
    }

    private static func ctLine(_ s: String, _ size: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("ArialMT" as CFString, size, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs as [NSAttributedString.Key: Any]))
    }

    private static func text(_ s: String, size: CGFloat, y: CGFloat, maxWidth: CGFloat, center: Bool, in ctx: CGContext) {
        var line = ctLine(s, size)
        var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if w > maxWidth {
            line = ctLine(s, size * maxWidth / w)
            w = maxWidth
        }
        let x = center ? (designSize.width - w) / 2 : 5.8
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    /// Рисует штамп в rect (origin — левый нижний угол). Высота определяется шириной.
    static func draw(_ info: SignatureInfo, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        let s = rect.width / designSize.width
        ctx.scaleBy(x: s, y: s)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(0.6)
        let box = CGRect(origin: .zero, size: designSize).insetBy(dx: 0.4, dy: 0.4)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.strokePath()

        text("ДОКУМЕНТ ПОДПИСАН ЭЛЕКТРОННОЙ ПОДПИСЬЮ", size: 6.2, y: 41, maxWidth: 177, center: true, in: ctx)
        let ys: [CGFloat] = [30, 22.5, 14.7, 6.5]
        for (l, y) in zip(lines(info), ys) {
            text(l, size: 5.7, y: y, maxWidth: 177, center: false, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Растр для превью (4x).
    static func previewImage(_ info: SignatureInfo) -> NSImage {
        let size = CGSize(width: designSize.width * 4, height: designSize.height * 4)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(info, in: ctx, rect: rect)
            return true
        }
    }
}
