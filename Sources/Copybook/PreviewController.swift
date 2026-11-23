import AppKit
import SwiftUI

@MainActor
final class PreviewModel: ObservableObject {
    @Published var item: ClipItem?
}

/// Large preview (Space) shown above the panel. Never takes keyboard focus.
@MainActor
final class PreviewController {
    private let panel: KeyPanel
    private let model = PreviewModel()
    private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                         styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                         backing: .buffered, defer: false)
        panel.allowsKey = false
        panel.level = WindowLevels.overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = FirstMouseHostingView(rootView: PreviewView(model: model, store: core.store, core: core))
        host.sizingOptions = []
        panel.contentView = makeGlassContainer(host, cornerRadius: 28)
    }

    var isVisible: Bool { panel.isVisible }
    var windowLevel: NSWindow.Level { panel.level }

    func show(_ item: ClipItem) {
        model.item = item
        let main = core.panelController.visibleFrame
        guard let screen = core.panelController.panel.screen ?? NSScreen.main else { return }
        // Above the panel if there's room there, otherwise below it.
        let vf = screen.visibleFrame
        if core.model.vertical {
            // To the left of the tall panel, and below the Stack if that is open.
            let maxX = main.minX - 14
            var top = vf.maxY - 12
            if let stack = core.stack.visibleFrame { top = min(top, stack.minY - 14) }
            let h = min(460, max(200, top - vf.minY - 12))
            let w = min(640, max(320, maxX - vf.minX - 12))
            let y = max(vf.minY + 12, min(top - h, main.midY - h / 2))
            panel.sharingType = Prefs.shared.showDuringScreenSharing ? .readOnly : .none
            panel.setFrame(NSRect(x: max(vf.minX + 12, maxX - w), y: y, width: w, height: h), display: true)
            panel.orderFrontRegardless()
            return
        }
        let spaceAbove = vf.maxY - main.maxY - 24
        let spaceBelow = main.minY - vf.minY - 24
        let above = spaceAbove >= spaceBelow
        let h = min(460, max(200, above ? spaceAbove : spaceBelow))
        let y = above ? main.maxY + 12 : main.minY - 12 - h
        // Usable horizontal span: the panel's width, minus the Stack column if it's open.
        var minX = main.minX + 20, maxX = main.maxX - 20
        if let stack = core.stack.visibleFrame, stack.intersects(NSRect(x: main.minX, y: y, width: main.width, height: h)) {
            if stack.midX > main.midX { maxX = min(maxX, stack.minX - 14) } else { minX = max(minX, stack.maxX + 14) }
        }
        let w = min(720, maxX - minX)
        let x = max(minX, min(main.midX - w / 2, maxX - w))
        panel.sharingType = Prefs.shared.showDuringScreenSharing ? .readOnly : .none
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

struct PreviewView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var store: Store
    let core: AppCore

    var body: some View {
        ZStack {
            if let item = model.item { page(item) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func page(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(item)
            Rectangle().fill(PanelStyle.hairline).frame(height: 1)
            content(item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(item.id)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.15), value: item.id)
    }

    private func header(_ item: ClipItem) -> some View {
        HStack(spacing: 8) {
            if let icon = AppInfo.icon(for: item.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(item.title ?? item.sourceAppName ?? item.kind.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PanelStyle.label)
                .lineLimit(1)
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 12))
                .foregroundStyle(PanelStyle.tertiary)
            Spacer()
            if item.kind == .link { Button("Open Link") { core.open(item) } }
            if item.kind == .file { Button("Show in Finder") { core.reveal(item) } }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @ViewBuilder
    private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView {
                Group {
                    if item.hasRichText, let data = store.data(item, key: "public.rtf"),
                       let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
                        Text(AttributedString(stripColors(rich)))
                    } else {
                        Text(item.text ?? "").font(.system(size: 14)).lineSpacing(3).foregroundStyle(PanelStyle.label)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        case .link:
            VStack(alignment: .leading, spacing: 12) {
                if let img = store.linkImage(item) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let t = item.linkTitle { Text(t).font(.system(size: 17, weight: .semibold)) }
                Text(item.text ?? "").font(.system(size: 13)).foregroundStyle(Color.accentColor).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            ZStack {
                Checkerboard().opacity(0.6)
                if let img = store.fullImage(item) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let w = item.imageWidth, let h = item.imageHeight {
                    Text("\(w) × \(h)").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.regularMaterial)).padding(10)
                }
            }
        case .color:
            colorPreview(item)
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.filePaths ?? [], id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading) {
                                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                                Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    if item.filePaths?.count == 1, let thumb = store.displayImage(item) {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 260)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
    }

    private func colorPreview(_ item: ClipItem) -> some View {
        let c = (ColorParser.parse(item.text ?? "") ?? .gray).usingColorSpace(.sRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let rows = [
            ("HEX", c.hexString),
            ("RGB", "\(Int(c.redComponent * 255)), \(Int(c.greenComponent * 255)), \(Int(c.blueComponent * 255))"),
            ("HSB", "\(Int(h * 360))°, \(Int(s * 100))%, \(Int(b * 100))%"),
            ("Alpha", "\(Int(a * 100))%"),
        ]
        return HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: c)).frame(width: 180)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Text(row.0).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                        Text(row.1).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Spacer()
            }
            Spacer()
        }
        .padding(18)
    }

    private func stripColors(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let r = NSRange(location: 0, length: m.length)
        m.removeAttribute(.foregroundColor, range: r)
        m.removeAttribute(.backgroundColor, range: r)
        return m
    }
}

struct EditorView: View {
    let initial: String
    let title: String
    let onFinish: (String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .padding(12)
            Divider()
            HStack {
                Text("\(text.count) characters").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onFinish(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") { onFinish(text) }.keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { text = initial }
    }
}
