import Foundation

/// Вложение исходного PDF и .sig в готовый PDF (инкрементальное обновление файла от CoreGraphics).
enum PDFAttachments {
    struct Item {
        var role: String      // "Original" | "Signature"
        var name: String
        var mime: String      // например "application/pdf"
        var data: Data
    }

    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "Не удалось вложить файлы в PDF (неожиданная структура файла)." }
    }

    private static func utf16Hex(_ s: String) -> String {
        "<FEFF" + s.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }

    private static func ascii(_ s: String) -> String {
        let a = s.unicodeScalars.map { $0.isASCII && $0 != "(" && $0 != ")" && $0 != "\\" ? Character($0) : "_" }
        return "(" + String(a) + ")"
    }

    static func append(to pdf: Data, items: [Item]) throws -> Data {
        guard let text = String(data: pdf, encoding: .isoLatin1),
              let sx = text.range(of: "startxref", options: .backwards) else { throw Failure.unsupported }
        let tail = text[sx.upperBound...].split(whereSeparator: \.isWhitespace)
        guard let prev = tail.first.flatMap({ Int($0) }),
              let tr = text.range(of: "trailer", options: .backwards, range: text.startIndex..<sx.lowerBound) else { throw Failure.unsupported }
        var trailer = String(text[tr.upperBound..<sx.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        func intValue(_ key: String, in s: String) -> Int? {
            guard let r = s.range(of: key + " ") else { return nil }
            return Int(s[r.upperBound...].prefix { $0.isNumber })
        }
        guard let size = intValue("/Size", in: trailer), let root = intValue("/Root", in: trailer),
              let ro = text.range(of: "\n\(root) 0 obj", options: .backwards),
              let eo = text.range(of: "endobj", range: ro.upperBound..<text.endIndex),
              let open = text[ro.upperBound..<eo.lowerBound].range(of: "<<"),
              let close = text[ro.upperBound..<eo.lowerBound].range(of: ">>", options: .backwards)
        else { throw Failure.unsupported }
        let catalogBody = String(text[open.upperBound..<close.lowerBound])

        let sorted = items.sorted { Array($0.name.utf16) .lexicographicallyPrecedes(Array($1.name.utf16)) }
        var out = pdf
        if out.last != 0x0A { out.append(0x0A) }
        var offsets: [(num: Int, off: Int)] = []
        var next = size
        var filespecs: [(item: Item, num: Int)] = []

        func add(_ s: String) { out.append(s.data(using: .isoLatin1)!) }

        for it in sorted {
            let streamNum = next, specNum = next + 1
            next += 2
            offsets.append((streamNum, out.count))
            let mime = it.mime.replacingOccurrences(of: "/", with: "#2F")
            add("\(streamNum) 0 obj\n<< /Type /EmbeddedFile /Subtype /\(mime) /StampSignRole /\(it.role) /Length \(it.data.count) /Params << /Size \(it.data.count) >> >>\nstream\n")
            out.append(it.data)
            add("\nendstream\nendobj\n")
            offsets.append((specNum, out.count))
            add("\(specNum) 0 obj\n<< /Type /Filespec /F \(ascii(it.name)) /UF \(utf16Hex(it.name)) /AFRelationship /Source /EF << /F \(streamNum) 0 R /UF \(streamNum) 0 R >> >>\nendobj\n")
            filespecs.append((it, specNum))
        }
        let names = filespecs.map { "\(utf16Hex($0.item.name)) \($0.num) 0 R" }.joined(separator: " ")
        let af = filespecs.map { "\($0.num) 0 R" }.joined(separator: " ")
        offsets.append((root, out.count))
        add("\(root) 0 obj\n<<\(catalogBody) /Names << /EmbeddedFiles << /Names [\(names)] >> >> /AF [\(af)] >>\nendobj\n")

        let xrefOff = out.count
        add("xref\n")
        let byNum = offsets.sorted { $0.num < $1.num }
        var i = 0
        while i < byNum.count {
            var j = i
            while j + 1 < byNum.count, byNum[j + 1].num == byNum[j].num + 1 { j += 1 }
            add("\(byNum[i].num) \(j - i + 1)\n")
            for k in i...j { add(String(format: "%010d 00000 n \n", byNum[k].off)) }
            i = j + 1
        }
        if let r = trailer.range(of: "/Size \(size)") { trailer.replaceSubrange(r, with: "/Size \(next) /Prev \(prev)") }
        add("trailer\n\(trailer)\nstartxref\n\(xrefOff)\n%%EOF\n")
        return out
    }

    /// Достаёт вложения, добавленные append(): роль → данные.
    static func extract(from pdf: Data) -> (document: Data, signature: Data)? {
        guard let text = String(data: pdf, encoding: .isoLatin1) else { return nil }
        var found: [String: Data] = [:]
        var from = text.startIndex
        while let m = text.range(of: "/StampSignRole /", range: from..<text.endIndex) {
            from = m.upperBound
            let role = String(text[m.upperBound...].prefix { $0.isLetter })
            guard let dictEnd = text.range(of: "stream\n", range: m.upperBound..<text.endIndex),
                  let lr = text.range(of: "/Length ", range: m.upperBound..<dictEnd.lowerBound),
                  let len = Int(text[lr.upperBound...].prefix { $0.isNumber }) else { continue }
            let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: dictEnd.upperBound)
            guard start + len <= pdf.count else { continue }
            found[role] = pdf.subdata(in: start..<(start + len))
        }
        guard let d = found["Original"], let s = found["Signature"] else { return nil }
        return (d, s)
    }
}
