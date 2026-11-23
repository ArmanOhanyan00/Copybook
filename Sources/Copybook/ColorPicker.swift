import AppKit
import CryptoKit
import SwiftUI

/// Picks a colour from anywhere on screen with the system magnifier (NSColorSampler, which
/// needs no screen-recording permission), copies it, and saves it to history as a colour clip.
@MainActor
final class ScreenColorPicker {
    enum Format: String, CaseIterable { case hex, rgb }

    private weak var core: AppCore?
    private var sampler: NSColorSampler?
    private var toast: NSPanel?

    init(core: AppCore) { self.core = core }

    var isPicking: Bool { sampler != nil }

    func pick() {
        guard let core, sampler == nil else { return }
        // Get the panel out of the way so everything underneath can be sampled.
        let reopenPanel = core.panelController.isVisible
        // Even a pinned panel steps aside so the whole screen can be sampled; it returns to its exact place.
        if reopenPanel { core.panelController.hide(animated: false, force: true) }
        core.preview.hide()

        let s = NSColorSampler()
        sampler = s
        // A beat so the panel is fully off screen before the loupe appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            s.show { [weak self] color in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sampler = nil
                    self.finish(color, reopenPanel: reopenPanel)
                }
            }
        }
    }

    private func finish(_ color: NSColor?, reopenPanel: Bool) {
        guard let core else { return }
        guard let color, let srgb = color.usingColorSpace(.sRGB) else {
            if reopenPanel { core.panelController.show() }   // cancelled with Esc
            return
        }
        let text = Self.string(for: srgb, format: core.prefs.colorFormat)

        var item = ClipItem(kind: .color)
        item.text = text
        item.sourceBundleID = Bundle.main.bundleIdentifier
        item.sourceAppName = "Colour Picker"
        item.contentHash = SHA256.hash(data: Data((ClipKind.color.rawValue + text).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let (saved, _) = core.store.add(item, blobs: [])
        core.monitor.ignore(changeCount: Paster.write([saved], store: core.store, plain: true))

        if reopenPanel {
            core.panelController.show()
            core.flash(saved.id, "Copied")
        } else {
            showToast(text: text, color: srgb)
        }
    }

    static func string(for c: NSColor, format: Format) -> String {
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()),
            b = Int((c.blueComponent * 255).rounded())
        let clamp = { (v: Int) in min(max(v, 0), 255) }
        switch format {
        case .hex: return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
        case .rgb: return "rgb(\(clamp(r)), \(clamp(g)), \(clamp(b)))"
        }
    }

    // MARK: Confirmation toast (when the panel wasn't open)

    private func showToast(text: String, color: NSColor) {
        toast?.orderOut(nil)
        let host = NSHostingView(rootView: ColorToast(text: text, color: Color(nsColor: color)))
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = WindowLevels.overlay
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host

        // Just below and right of the pointer, kept on screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - host.fittingSize.height - 14)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - host.fittingSize.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - host.fittingSize.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        toast = panel
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self, weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
                if self?.toast === panel { self?.toast = nil }
            }
        }
    }
}

private struct ColorToast: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("Copied").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 9).padding(.trailing, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .padding(10)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .fixedSize()
    }
}
