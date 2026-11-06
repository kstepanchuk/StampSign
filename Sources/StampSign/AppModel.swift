import AppKit
import PDFKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var pdfURL: URL?
    @Published var sigURL: URL?
    @Published var document: PDFDocument?
    @Published var info: SignatureInfo? {
        didSet { stampImage = info.map(StampRenderer.previewImage) }
    }
    @Published var message: String?
    @Published var savedURL: URL?
    @Published var page = 0 { didSet { updatePageImage() } }
    @Published var stampPage = 0
    @Published var allPages = false
    @Published var placement = Placement(x: 0, y: 20, width: 190) { didSet { persist() } }
    @Published var embed: Bool = UserDefaults.standard.object(forKey: "embed") as? Bool ?? true {
        didSet { defaults.set(embed, forKey: "embed") }
    }
    /// Открыт уже проштампованный PDF: исходник и .sig берём из его вложений.
    @Published var fromAttachment = false
    private var attached: (document: Data, signature: Data)?
    @Published var verification: VerificationResult?
    @Published var verifying = false
    private var verifyTask: Task<Void, Never>?
    @Published var pageImage: NSImage?
    @Published var stampImage: NSImage?

    private let defaults = UserDefaults.standard

    static let zones: [(id: String, name: String)] = [
        ("Europe/Kaliningrad", "Калининград (UTC+2)"), ("Europe/Moscow", "Москва (UTC+3)"),
        ("Europe/Samara", "Самара (UTC+4)"), ("Asia/Yekaterinburg", "Екатеринбург (UTC+5)"),
        ("Asia/Novosibirsk", "Новосибирск (UTC+7)"), ("Asia/Vladivostok", "Владивосток (UTC+10)"),
    ]
    @Published var zoneID: String = UserDefaults.standard.string(forKey: "tz") ?? "Europe/Moscow" {
        didSet {
            StampRenderer.timeZone = TimeZone(identifier: zoneID) ?? .current
            defaults.set(zoneID, forKey: "tz")
            if let i = info { stampImage = StampRenderer.previewImage(i) }
        }
    }

    init() {
        StampRenderer.timeZone = TimeZone(identifier: zoneID) ?? .current
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    var pageSize: CGSize {
        guard let p = document?.page(at: page) else { return CGSize(width: 595, height: 842) }
        let b = p.bounds(for: .cropBox)
        return p.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    var stampVisibleOnCurrentPage: Bool { allPages || stampPage == page }

    // MARK: Файлы

    func handle(urls: [URL]) {
        message = nil
        savedURL = nil
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "pdf": setPDF(url)
            case "sig", "p7s", "p7m", "cms", "p7": setSig(url)
            default: message = "Не распознан файл: \(url.lastPathComponent)"
            }
        }
        if sigURL == nil, let pdf = pdfURL {
            let guess = URL(fileURLWithPath: pdf.path + ".sig")
            if FileManager.default.fileExists(atPath: guess.path) { setSig(guess) }
        }
        if pdfURL == nil, let sig = sigURL, sig.lastPathComponent.lowercased().hasSuffix(".pdf.sig") {
            let guess = sig.deletingPathExtension()
            if FileManager.default.fileExists(atPath: guess.path) { setPDF(guess) }
        }
        scheduleVerify()
    }

    private func scheduleVerify() {
        verifyTask?.cancel()
        verification = nil
        let att = attached
        guard let pdf = pdfURL, sigURL != nil || att != nil else { verifying = false; return }
        let sig = sigURL
        verifying = true
        verifyTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> VerificationResult? in
                if let sig, let d = try? Data(contentsOf: pdf), let s = try? Data(contentsOf: sig) {
                    return SigVerifier.verify(sig: s, document: d)
                }
                if let att { return SigVerifier.verify(sig: att.signature, document: att.document) }
                return nil
            }.value
            guard !Task.isCancelled else { return }
            self?.verification = result
            self?.verifying = false
        }
    }

    private func setPDF(_ url: URL) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            message = "Не удалось открыть PDF: \(url.lastPathComponent)"
            return
        }
        pdfURL = url
        attached = nil
        fromAttachment = false
        if let data = try? Data(contentsOf: url), let att = PDFAttachments.extract(from: data) {
            attached = att
            fromAttachment = true
            if sigURL == nil { info = try? SigParser.parse(att.signature) }
        }
        document = doc
        page = doc.pageCount - 1
        stampPage = page
        updatePageImage()
        applySavedPlacement()
    }

    private func setSig(_ url: URL) {
        do {
            info = try SigParser.parse(Data(contentsOf: url))
            sigURL = url
            attached = nil
            fromAttachment = false
        } catch {
            info = nil
            sigURL = nil
            message = error.localizedDescription
        }
    }

    // MARK: Страница и размещение

    private func updatePageImage() {
        guard let p = document?.page(at: page) else { pageImage = nil; return }
        let s = pageSize
        pageImage = p.thumbnail(of: CGSize(width: 1400, height: 1400 * s.height / s.width), for: .cropBox)
    }

    private func applySavedPlacement() {
        let s = pageSize
        let fw = defaults.object(forKey: "fw") as? Double ?? Double(190 / s.width)
        let fx = defaults.object(forKey: "fx") as? Double ?? (1 - fw) / 2
        let fy = defaults.object(forKey: "fy") as? Double ?? Double(20 / s.height)
        placement = Placement(x: fx * s.width, y: fy * s.height, width: fw * s.width)
    }

    private func persist() {
        guard document != nil else { return }
        let s = pageSize
        defaults.set(placement.x / s.width, forKey: "fx")
        defaults.set(placement.y / s.height, forKey: "fy")
        defaults.set(placement.width / s.width, forKey: "fw")
    }

    enum Preset { case bottomLeft, bottomCenter, bottomRight, topRight }

    func apply(_ preset: Preset) {
        let s = pageSize, m = 20.0
        var p = placement
        switch preset {
        case .bottomLeft: p.x = m; p.y = m
        case .bottomCenter: p.x = (s.width - p.width) / 2; p.y = m
        case .bottomRight: p.x = s.width - p.width - m; p.y = m
        case .topRight: p.x = s.width - p.width - m; p.y = s.height - p.height - m
        }
        stampPage = page
        placement = p
    }

    func clamp(_ p: Placement) -> Placement {
        let s = pageSize
        var q = p
        q.width = min(max(q.width, 80), s.width)
        q.x = min(max(q.x, 0), s.width - q.width)
        q.y = min(max(q.y, 0), s.height - q.height)
        return q
    }

    func nudge(dx: Double, dy: Double) {
        var p = placement
        p.x += dx; p.y += dy
        stampPage = page
        placement = clamp(p)
    }

    // MARK: Экспорт

    func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK { handle(urls: panel.urls) }
    }

    func openSig() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { handle(urls: panel.urls) }
    }

    func save() {
        guard let pdfURL, let info, let sigURL, !fromAttachment else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = pdfURL.deletingLastPathComponent()
        panel.nameFieldStringValue = pdfURL.lastPathComponent + ".stamp.pdf"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            var items: [PDFAttachments.Item] = []
            if embed {
                items = [
                    .init(role: "Original", name: pdfURL.lastPathComponent, mime: "application/pdf", data: try Data(contentsOf: pdfURL)),
                    .init(role: "Signature", name: sigURL.lastPathComponent, mime: "application/pkcs7-signature", data: try Data(contentsOf: sigURL)),
                ]
            }
            try PDFExporter.export(source: pdfURL, info: info, placement: placement,
                                   pages: allPages ? nil : [stampPage], attachments: items, to: dest)
            savedURL = dest
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
