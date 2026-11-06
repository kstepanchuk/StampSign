import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var m = AppModel()
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 0) {
            PagePreview(m: m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            Sidebar(m: m).frame(width: 290)
        }
        .frame(minWidth: 940, minHeight: 640)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(u)
                    }
                }
                m.handle(urls: urls)
            }
            return true
        }
    }
}

// MARK: - Превью с перетаскиваемым штампом

struct PagePreview: View {
    @ObservedObject var m: AppModel
    @State private var dragStart: Placement?
    @State private var resizeStart: Placement?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            if let img = m.pageImage {
                let ps = m.pageSize
                let k = min((geo.size.width - 40) / ps.width, (geo.size.height - 40) / ps.height)
                let w = ps.width * k, h = ps.height * k
                let pl = m.placement
                ZStack(alignment: .topLeading) {
                    Image(nsImage: img).resizable().frame(width: w, height: h)
                        .background(Color.white).shadow(radius: 6, y: 2)
                    if let stamp = m.stampImage, m.stampVisibleOnCurrentPage {
                        Image(nsImage: stamp).resizable()
                            .frame(width: pl.width * k, height: pl.height * k)
                            .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4])))
                            .offset(x: pl.x * k, y: (ps.height - pl.y - pl.height) * k)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("page"))
                                .onChanged { v in
                                    let s = dragStart ?? m.placement
                                    dragStart = s
                                    var p = s
                                    p.x = s.x + v.translation.width / k
                                    p.y = s.y - v.translation.height / k
                                    m.stampPage = m.page
                                    m.placement = m.clamp(snap(p, ps))
                                }
                                .onEnded { _ in dragStart = nil })
                        Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .offset(x: (pl.x + pl.width) * k - 6, y: (ps.height - pl.y) * k - 6)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("page"))
                                .onChanged { v in
                                    let s = resizeStart ?? m.placement
                                    resizeStart = s
                                    var p = s
                                    p.width = s.width + v.translation.width / k
                                    // верхний левый угол остаётся на месте
                                    p.y = s.y + s.height - p.height
                                    m.placement = m.clamp(p)
                                }
                                .onEnded { _ in resizeStart = nil })
                    }
                }
                .coordinateSpace(name: "page")
                .frame(width: w, height: h)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Перетащите сюда PDF и файл .sig").font(.title3)
                    Text("Затем перетащите штамп туда, где он должен стоять").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
            switch press.key {
            case .leftArrow: m.nudge(dx: -step, dy: 0)
            case .rightArrow: m.nudge(dx: step, dy: 0)
            case .upArrow: m.nudge(dx: 0, dy: step)
            case .downArrow: m.nudge(dx: 0, dy: -step)
            default: return .ignored
            }
            return .handled
        }
        .onTapGesture { focused = true }
    }

    /// Прилипание к краям/центру (отключается зажатым ⌥).
    private func snap(_ p: Placement, _ ps: CGSize) -> Placement {
        guard !NSEvent.modifierFlags.contains(.option) else { return p }
        var q = p
        let t = 6.0, margin = 20.0
        for cx in [margin, (ps.width - p.width) / 2, ps.width - p.width - margin] where abs(q.x - cx) < t { q.x = cx }
        for cy in [margin, ps.height - p.height - margin] where abs(q.y - cy) < t { q.y = cy }
        return q
    }
}

// MARK: - Боковая панель

struct Sidebar: View {
    @ObservedObject var m: AppModel

    private func num(_ keyPath: WritableKeyPath<Placement, Double>) -> Binding<Double> {
        Binding(
            get: { m.placement[keyPath: keyPath] },
            set: { v in
                var p = m.placement
                p[keyPath: keyPath] = v
                m.stampPage = m.page
                m.placement = m.clamp(p)
            })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FileSlot(icon: "doc.richtext", title: "PDF-документ", url: m.pdfURL, action: m.openPDF)
                FileSlot(icon: "signature", title: "Файл подписи (.sig)", url: m.sigURL,
                         placeholder: m.fromAttachment ? "Берётся из вложений PDF" : nil, action: m.openSig)
                if m.fromAttachment {
                    Text("Это уже проштампованный PDF: исходный документ и подпись взяты из его вложений, проверка выполнена по ним. Чтобы поставить штамп заново, откройте исходный PDF.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let i = m.info {
                    GroupBox("Подпись") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(StampRenderer.lines(i), id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            Picker("Часовой пояс", selection: $m.zoneID) {
                                ForEach(AppModel.zones, id: \.id) { Text($0.name).tag($0.id) }
                            }.font(.caption).padding(.top, 4)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if m.verifying {
                    HStack { ProgressView().controlSize(.small); Text("Проверяю подпись…").font(.caption) }
                } else if let v = m.verification {
                    VerificationBox(v: v)
                }

                if m.document != nil {
                    GroupBox("Размещение штампа") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button { m.page -= 1 } label: { Image(systemName: "chevron.left") }
                                    .disabled(m.page == 0)
                                Text("Страница \(m.page + 1) из \(m.pageCount)").frame(maxWidth: .infinity)
                                Button { m.page += 1 } label: { Image(systemName: "chevron.right") }
                                    .disabled(m.page >= m.pageCount - 1)
                            }
                            Toggle("Штамп на всех страницах", isOn: $m.allPages)
                            if !m.stampVisibleOnCurrentPage {
                                Button("Поставить штамп на эту страницу") { m.stampPage = m.page }
                            }
                            HStack(spacing: 6) {
                                Button { m.apply(.bottomLeft) } label: { Label("Лево", systemImage: "arrow.down.left") }
                                Button { m.apply(.bottomCenter) } label: { Label("Центр", systemImage: "arrow.down") }
                                Button { m.apply(.bottomRight) } label: { Label("Право", systemImage: "arrow.down.right") }
                            }.labelStyle(.titleAndIcon).controlSize(.small)
                            Button { m.apply(.topRight) } label: { Label("Верх справа", systemImage: "arrow.up.right") }
                                .controlSize(.small)
                            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                                GridRow { Text("X, pt"); TextField("", value: num(\.x), format: .number.precision(.fractionLength(0...1))) }
                                GridRow { Text("Y, pt"); TextField("", value: num(\.y), format: .number.precision(.fractionLength(0...1))) }
                                GridRow { Text("Ширина"); TextField("", value: num(\.width), format: .number.precision(.fractionLength(0...1))) }
                            }.textFieldStyle(.roundedBorder)
                            Text("Тяните штамп мышью, угловая точка — размер. Стрелки двигают на 1 pt (⇧ — на 10). ⌥ отключает прилипание.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if let msg = m.message {
                    Text(msg).font(.callout).foregroundStyle(.red)
                }
                if let saved = m.savedURL {
                    HStack {
                        Label("Сохранено", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    }.font(.callout)
                }

                Toggle("Вложить в PDF исходник и .sig (для проверки подписи)", isOn: $m.embed)
                    .font(.caption).toggleStyle(.checkbox)
                    .disabled(m.fromAttachment)

                Button { m.save() } label: {
                    Text("Сохранить PDF со штампом…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(m.pdfURL == nil || m.info == nil || m.fromAttachment)
            }
            .padding(16)
        }
    }
}

struct FileSlot: View {
    let icon: String
    let title: String
    let url: URL?
    var placeholder: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: url == nil && placeholder == nil ? icon : "checkmark.circle.fill")
                    .foregroundStyle(url == nil && placeholder == nil ? Color.secondary : Color.green)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(url?.lastPathComponent ?? placeholder ?? "Перетащите или нажмите")
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: url == nil ? [5] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VerificationBox: View {
    let v: VerificationResult

    private func row(_ s: VerificationResult.State, ok: String, bad: String, unknown: String) -> some View {
        let (icon, color, text): (String, Color, String) = switch s {
        case .ok: ("checkmark.circle.fill", .green, ok)
        case .bad: ("xmark.octagon.fill", .red, bad)
        case .unsupported, .unknown: ("questionmark.circle.fill", .orange, unknown)
        }
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.caption)
    }

    var body: some View {
        GroupBox("Проверка подписи") {
            VStack(alignment: .leading, spacing: 6) {
                row(v.integrity, ok: "Документ не изменён после подписания",
                    bad: "Документ изменён после подписания", unknown: "Целостность документа проверить не удалось")
                row(v.signature, ok: "Электронная подпись верна",
                    bad: "Электронная подпись НЕ верна", unknown: "Подпись проверить не удалось")
                row(v.validity, ok: "Сертификат действовал в момент подписания",
                    bad: "Сертификат не действовал в момент подписания", unknown: "Срок действия сертификата не проверен")
                row(v.chain, ok: "Сертификат подписан УЦ" + (v.chainRoot.map { " «\($0)»" } ?? "") + " (подпись УЦ верна)",
                    bad: "Подпись УЦ на сертификате неверна", unknown: "Цепочку сертификатов проверить не удалось")
                ForEach(v.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                Text("Доверие к корневому УЦ и отзыв сертификата не проверяются.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
