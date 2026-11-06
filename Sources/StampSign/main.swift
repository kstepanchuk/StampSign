import SwiftUI

struct StampSignApp: App {
    var body: some Scene {
        WindowGroup("StampSign") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// Тестовый режим без GUI: StampSign --cli in.pdf in.sig out.pdf [x y width page|all]
/// (page — номер с 1, по умолчанию последняя; x/y/width в pt от левого нижнего угла)
func runCLI(_ a: [String]) -> Int32 {
    guard a.count >= 3 else { fputs("usage: --cli in.pdf in.sig out.pdf [x y width page|all]\n", stderr); return 2 }
    let pdf = URL(fileURLWithPath: a[0]), sig = URL(fileURLWithPath: a[1]), out = URL(fileURLWithPath: a[2])
    do {
        let info = try SigParser.parse(Data(contentsOf: sig))
        print("serial: \(info.serialHex)")
        print("owner:  \(info.owner)")
        for l in StampRenderer.lines(info) { print(l) }
        let n = PDFExporter.pageCount(pdf)
        let pageArg = a.count > 6 ? a[6] : "\(n)"
        let pages: Set<Int>? = pageArg == "all" ? nil : [(Int(pageArg) ?? n) - 1]
        let last = (pages?.first ?? n - 1)
        let size = PDFExporter.firstPageSize(pdf, page: last) ?? CGSize(width: 595, height: 842)
        let w = a.count > 5 ? Double(a[5]) ?? 190 : 190
        let x = a.count > 3 ? Double(a[3]) ?? 0 : (Double(size.width) - w) / 2
        let y = a.count > 4 ? Double(a[4]) ?? 20 : 20
        let att = [
            PDFAttachments.Item(role: "Original", name: pdf.lastPathComponent, mime: "application/pdf", data: try Data(contentsOf: pdf)),
            PDFAttachments.Item(role: "Signature", name: sig.lastPathComponent, mime: "application/pkcs7-signature", data: try Data(contentsOf: sig)),
        ]
        try PDFExporter.export(source: pdf, info: info, placement: Placement(x: x, y: y, width: w), pages: pages, attachments: att, to: out)
        print("saved \(out.path)")
        return 0
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

let args = CommandLine.arguments
if args.count >= 2, args[1] == "--streebog" {
    // --streebog 256|512 string-or-@file
    let bits = Int(args[2]) ?? 256
    let data = args[3].hasPrefix("@") ? (try! Data(contentsOf: URL(fileURLWithPath: String(args[3].dropFirst())))) : Data(args[3].utf8)
    print(Streebog.hash(data, bits: bits).map { String(format: "%02x", $0) }.joined())
} else if args.count >= 4, args[1] == "--verify" || args[1] == "--verify-debug" {
    let sigData = try! Data(contentsOf: URL(fileURLWithPath: args[3]))
    if args[1] == "--verify-debug" {
        SigVerifier.debugConventions(sig: sigData)
    } else {
        let t0 = Date()
        let r = SigVerifier.verify(sig: sigData, document: try! Data(contentsOf: URL(fileURLWithPath: args[2])))
        print(r, String(format: "%.2fs", Date().timeIntervalSince(t0)))
    }
    fflush(stdout)
    exit(0)
} else if args.count >= 3, args[1] == "--verify-embedded" {
    // StampSign --verify-embedded stamped.pdf : проверка по вложениям штампованного PDF
    guard let att = PDFAttachments.extract(from: try! Data(contentsOf: URL(fileURLWithPath: args[2]))) else {
        print("вложений не найдено"); exit(1)
    }
    print(SigVerifier.verify(sig: att.signature, document: att.document))
    fflush(stdout); exit(0)
} else if args.count >= 2, args[1] == "--cli" {
    exit(runCLI(Array(args.dropFirst(2))))
} else {
    StampSignApp.main()
}
