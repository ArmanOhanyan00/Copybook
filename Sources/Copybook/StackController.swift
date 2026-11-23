import AppKit
import Carbon
import SwiftUI

/// The stack: collect several clips, then paste them one by one in order with ⌘V.
@MainActor
final class StackController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var isActive = false
    /// Whether Copybook may watch for ⌘V and press it (Accessibility).
    @Published private(set) var hasAccess = Paster.isTrusted
    private var accessTimer: Timer?
    private var positioning = false

    static let width: CGFloat = 288
    private static let originKey = "stackOrigin"

    private unowned let core: AppCore
    private var panel: KeyPanel?
    private var keyMonitor: Any?
    private var pastingAll = false

    init(core: AppCore) {
        self.core = core
        super.init()
    }

    func toggle() { isActive ? close() : open() }

    func open() {
        guard !isActive else { panel?.orderFrontRegardless(); return }
        isActive = true
        refreshAccess()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command, Int(e.keyCode) == kVK_ANSI_V else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self?.didPasteFromStack() }
        }
        showPanel()
        prime()
    }

    func close() {
        isActive = false
        accessTimer?.invalidate()
        accessTimer = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        panel?.orderOut(nil)
        items.removeAll()
    }

    func add(_ new: [ClipItem]) {
        if !isActive { open() }
        items.append(contentsOf: new)
        prime()
    }

    func didCapture(_ item: ClipItem) {
        guard isActive, !pastingAll else { return }
        items.append(item)
        prime()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        prime()
    }

    func reverse() {
        items.reverse()
        prime()
    }

    func clear() { items.removeAll() }

    private func refreshAccess() {
        let now = Paster.isTrusted
        if now != hasAccess { withAnimation(Theme.snappy) { hasAccess = now } }
    }

    /// Frame of the stack window while it is on screen (used to keep the preview clear of it).
    var windowLevel: NSWindow.Level { panel?.level ?? WindowLevels.overlay }

    var visibleFrame: NSRect? { (panel?.isVisible ?? false) ? panel?.frame : nil }

    /// Keeps the stack in the right-hand column, always above the band the main panel uses.
    func reposition() {
        guard let panel, panel.isVisible else { return }
        let screen = core.panelController.panel.isVisible ? (core.panelController.panel.screen ?? panel.screen) : panel.screen
        guard let screen = screen ?? NSScreen.main else { return }
        positioning = true
        panel.setFrame(frame(on: screen), display: true, animate: false)
        positioning = false
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let w = Self.width
        // Wherever the panel is (or will open), keep 14 pt clear of it.
        let pc = core.panelController
        let panelFrame = (pc.panel.isVisible ? pc.visibleFrame : pc.targetFrame().insetBy(dx: PanelController.margin, dy: PanelController.margin)).insetBy(dx: -14, dy: -14)
        if core.model.vertical {
            // A tall panel on the side: the stack goes to its left, top-aligned.
            let room = panelFrame.minX - vf.minX - 12
            let sw = min(w, max(220, room))
            let h = max(220, min(440, vf.height - 24))
            var f = NSRect(x: panelFrame.minX - sw, y: vf.maxY - 12 - h, width: sw, height: h)
            if let saved = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString) {
                f.origin.y = min(max(saved.y, vf.minY + 4), vf.maxY - h - 4)
            }
            f.origin.x = max(f.origin.x, vf.minX + 4)
            return f
        }
        let roomAbove = vf.maxY - 12 - panelFrame.maxY
        let roomBelow = panelFrame.minY - vf.minY - 12
        let useAbove = roomAbove >= roomBelow
        let h = max(220, min(440, useAbove ? roomAbove : roomBelow))
        var origin = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString)
            ?? NSPoint(x: vf.maxX - w - 12, y: useAbove ? vf.maxY - 12 - h : vf.minY + 12)
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - w - 8)
        origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - h - 4)
        var f = NSRect(x: origin.x, y: origin.y, width: w, height: h)
        if f.intersects(panelFrame) {
            f.origin.y = useAbove ? max(f.origin.y, panelFrame.maxY) : min(f.origin.y, panelFrame.minY - h)
        }
        return f
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioning, let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
        reposition()
    }

    /// Keeps the next clip in the stack on the system pasteboard.
    private func prime() {
        guard let next = items.first else { return }
        core.monitor.ignore(changeCount: Paster.write([next], store: core.store, plain: Prefs.shared.alwaysPlainText))
    }

    private func didPasteFromStack() {
        guard isActive, !pastingAll, !items.isEmpty else { return }
        items.removeFirst()
        prime()
    }

    func pasteAll() {
        let batch = items
        guard !batch.isEmpty else { return }
        let plain = Prefs.shared.alwaysPlainText
        guard Paster.isTrusted else { refreshAccess(); return }
        pastingAll = true
        if batch.allSatisfy({ $0.kind.isTextual }) {
            core.monitor.ignore(changeCount: Paster.write(batch, store: core.store, plain: plain))
            Paster.sendCommandV()
            finishPasteAll(after: 0.3)
            return
        }
        for (i, item) in batch.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.35) { [weak self] in
                guard let self else { return }
                self.core.monitor.ignore(changeCount: Paster.write([item], store: self.core.store, plain: plain))
                Paster.sendCommandV()
            }
        }
        finishPasteAll(after: Double(batch.count) * 0.35 + 0.3)
    }

    private func finishPasteAll(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pastingAll = false
            self?.items.removeAll()
        }
    }

    private func showPanel() {
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 440),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
            p.allowsKey = false
            p.becomesKeyOnlyIfNeeded = true
            p.level = WindowLevels.overlay
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            p.delegate = self
            let host = FirstMouseHostingView(rootView: StackView(stack: self, store: core.store))
            host.sizingOptions = []
            p.contentView = makeGlassContainer(host, cornerRadius: 28)
            panel = p
        }
        guard let panel else { return }
        panel.sharingType = Prefs.shared.showDuringScreenSharing ? .readOnly : .none
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            positioning = true
            panel.setFrame(frame(on: screen), display: true)
            positioning = false
        }
        panel.orderFrontRegardless()
    }
}

struct StackView: View {
    @ObservedObject var stack: StackController
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            header
            if !stack.hasAccess { accessNote }
            if stack.items.isEmpty { emptyState } else { list }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Stack").font(.system(size: 14, weight: .semibold)).foregroundStyle(PanelStyle.label)
            Text("\(stack.items.count)")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(PanelStyle.secondary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: stack.items.count)
            Spacer()
            Button { stack.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelStyle.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Stack")
            .accessibilityLabel("Close Stack")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var accessNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The stack follows your ⌘V presses, so it needs Accessibility access.")
                .font(.system(size: 12)).foregroundStyle(PanelStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { Paster.requestTrustFromUser() }.buttonStyle(.capsule)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PanelStyle.cardBackground.opacity(0.7)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Stack is empty").font(.system(size: 13, weight: .semibold)).foregroundStyle(PanelStyle.secondary)
            Text("Copy items, then press ⌘V\nto paste them in order.")
                .font(.system(size: 12)).foregroundStyle(PanelStyle.tertiary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(stack.items.enumerated()), id: \.element.id) { pair in
                    StackRow(item: pair.element, isNext: pair.offset == 0, store: store)
                        .contextMenu { Button("Remove") { stack.remove(pair.element.id) } }
                }
            }
            .padding(.horizontal, 12)
            .animation(.easeOut(duration: 0.18), value: stack.items.map(\.id))
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Paste everything") { stack.pasteAll() }
                .buttonStyle(.capsuleProminent)
                .disabled(stack.items.isEmpty)
            Spacer()
            footerButton("arrow.up.arrow.down", help: "Flip the order", enabled: stack.items.count > 1) { stack.reverse() }
            footerButton("trash", help: "Clear the stack", enabled: !stack.items.isEmpty) { stack.clear() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func footerButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(PanelStyle.secondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct StackRow: View {
    let item: ClipItem
    let isNext: Bool
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            thumb
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(summary).font(.system(size: 12.5)).foregroundStyle(PanelStyle.label).lineLimit(2)
                if isNext {
                    Text("Next").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isNext ? Color.accentColor.opacity(0.14) : PanelStyle.cardBackground.opacity(0.7)))
    }

    @ViewBuilder
    private var thumb: some View {
        if item.kind == .image, let t = store.thumbnail(item) {
            Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
        } else if let icon = AppInfo.icon(for: item.sourceBundleID) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: item.kind.symbol).foregroundStyle(PanelStyle.secondary)
        }
    }

    private var summary: String {
        switch item.kind {
        case .image: return "Image" + (item.imageWidth.map { " · \($0) × \(item.imageHeight ?? 0)" } ?? "")
        case .file: return (item.filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        default: return item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
}
