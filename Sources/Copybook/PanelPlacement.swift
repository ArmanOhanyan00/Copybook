import AppKit
import SwiftUI

// Moving and resizing the panel: a grab handle on the top edge, resize edges all round,
// and a prompt afterwards asking whether to keep the new size and position.

enum WindowDragMode {
    case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
}

/// The grab handle at the top of the panel: drags the whole window around.
final class WindowDragView: NSView {
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    private var changed = false
    /// True only for a drag that began here (a pinned panel ignores the grip entirely).
    private var active = false
    private var pendingFrame: NSRect?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        if !AppCore.shared.model.pinned { addCursorRect(bounds, cursor: .openHand) }
    }

    /// Cursor for each resize zone (used by the panel's border).
    static func cursor(for mode: WindowDragMode) -> NSCursor {
        switch mode {
        case .move: return .openHand
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight, .topRight, .bottomLeft:
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition = {
                    switch mode {
                    case .topLeft: return .topLeft
                    case .topRight: return .topRight
                    case .bottomLeft: return .bottomLeft
                    default: return .bottomRight
                    }
                }()
                return NSCursor.frameResize(position: position, directions: .all)
            }
            return .crosshair
        }
    }

    override func mouseDown(with event: NSEvent) {
        active = false
        guard let window, !AppCore.shared.model.pinned else { return }
        active = true
        if ProcessInfo.processInfo.environment["COPYBOOK_DEBUG_FRAME"] != nil {
            FileHandle.standardError.write(Data("grip down · window \(window.frame)\n".utf8))
        }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        changed = false
        NSCursor.closedHand.push()
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard active else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        if !changed && hypot(dx, dy) < 2 { return }
        changed = true
        var f = startFrame
        f.origin.x += dx
        f.origin.y += dy
        let schedule = pendingFrame == nil
        pendingFrame = f
        if schedule {
            RunLoop.main.perform(inModes: [.eventTracking, .default, .modalPanel]) { [weak self] in
                MainActor.assumeIsolated { self?.applyPendingFrame() }
            }
        }
    }

    private func applyPendingFrame() {
        guard let f = pendingFrame, let window else { pendingFrame = nil; return }
        pendingFrame = nil
        guard f != window.frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(f, display: true)
        window.invalidateShadow()
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard active else { return }
        active = false
        applyPendingFrame()
        NSCursor.pop()
        if changed { onEnd() }
    }
}

struct WindowDragArea: NSViewRepresentable {
    let onBegin: () -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> WindowDragView {
        let v = WindowDragView()
        v.onBegin = onBegin
        v.onEnd = onEnd
        return v
    }

    func updateNSView(_ v: WindowDragView, context: Context) {
        v.onBegin = onBegin
        v.onEnd = onEnd
        v.window?.invalidateCursorRects(for: v)   // the hand cursor goes away while pinned
    }
}

/// The grab handle (top centre). Resizing happens on the panel's invisible border (PanelFrameView).
struct PlacementHandles: View {
    let core: AppCore
    @ObservedObject var model: PanelModel
    @State private var hoveringGrip = false

    init(core: AppCore) {
        self.core = core
        _model = ObservedObject(wrappedValue: core.model)
    }

    var body: some View {
        let begin = { core.panelController.beginPlacementChange() }
        let end = { core.panelController.endPlacementChange() }
        VStack {
            // The whole strip along the top edge moves the panel; the pill just shows where.
            // While pinned the strip is locked and shows a pin instead.
            ZStack {
                WindowDragArea(onBegin: begin, onEnd: end)
                if model.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PanelStyle.accent.opacity(0.9))
                        .allowsHitTesting(false)
                } else {
                    Capsule()
                        .fill(PanelStyle.secondary.opacity(hoveringGrip ? 0.75 : 0.35))
                        .frame(width: hoveringGrip ? 46 : 36, height: 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: PanelStyle.gripStrip)
            .padding(.horizontal, 40)
            .onHover { h in withAnimation(PanelStyle.quick) { hoveringGrip = h } }
            .help(model.pinned ? "Pinned. Unpin to move or resize." : "Drag to move")
            .accessibilityElement()
            .accessibilityLabel("Move panel")
            Spacer()
        }
    }
}

/// Asked after a move or resize, over a blurred panel.
struct PlacementPrompt: View {
    let core: AppCore

    var body: some View {
        ZStack {
            // Rounded like the panel: a square dim layer shows up in the corners (and squares
            // off the panel's shadow) while the prompt is open.
            RoundedRectangle(cornerRadius: PanelStyle.panelRadius, style: .circular)
                .fill(Color.black.opacity(0.06))
                .contentShape(Rectangle())
                .onTapGesture {}   // swallow clicks on the blurred content
            VStack(spacing: 14) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(PanelStyle.accent)
                    .symbolEffect(.bounce, value: true)
                VStack(spacing: 5) {
                    Text("Keep this size and position?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PanelStyle.label)
                    Text("Always opens Copybook like this every time. Just for now goes back to the usual place once you close it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PanelStyle.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Just for now") { core.panelController.keepPlacement(always: false) }
                        .buttonStyle(.capsule)
                        .keyboardShortcut(.cancelAction)
                    Button("Always") { core.panelController.keepPlacement(always: true) }
                        .buttonStyle(.capsuleProminent)
                        .keyboardShortcut(.defaultAction)
                }
                Button("Reset to default") { core.panelController.resetPlacement() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PanelStyle.secondary)
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
            .frame(maxWidth: 360)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial))
            .modifier(GlassCard())
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        }
        // The card's shadow reaches past a narrow panel's edge; cut it at the panel's own rounded shape so
        // nothing shows outside it.
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.panelRadius, style: .circular))
    }
}

/// Liquid Glass rounded card on macOS 26+, material before.
private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            content
        }
    }
}

// Card size travels through the environment so every card can scale with the panel.
private struct CardSizeKey: EnvironmentKey {
    static let defaultValue = PanelStyle.card
}

private struct VerticalCardsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cardSize: CGSize {
        get { self[CardSizeKey.self] }
        set { self[CardSizeKey.self] = newValue }
    }

    /// The panel is in its vertical layout (wide, short cards stacked top to bottom).
    var verticalCards: Bool {
        get { self[VerticalCardsKey.self] }
        set { self[VerticalCardsKey.self] = newValue }
    }
}
