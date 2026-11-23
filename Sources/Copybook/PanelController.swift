import AppKit
import Carbon
import SwiftUI

/// Where Copybook's floating windows sit in the stack of everything on screen. Measured on macOS:
/// normal app windows are 0, apps' floating windows 3, modal panels 8, Stage Manager 16–17, the Dock
/// 20, Notification Centre and Siri 23, the menu bar 24, status items 25 and popup menus 101.
/// Copybook sits at 15: above every app window, but below the Dock (so its magnified icons and
/// menus draw over us), notifications, Stage Manager, the menu bar and everything else from the system.
enum WindowLevels {
    static let overlay = NSWindow.Level(rawValue: 15)
}

final class KeyPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Wraps content in Liquid Glass on macOS 26+, falling back to a vibrant blur.
@MainActor
func makeGlassContainer(_ content: NSView, cornerRadius: CGFloat) -> NSView {
    let variant = ProcessInfo.processInfo.environment["COPYBOOK_VARIANT"] ?? ""
    if #available(macOS 26.0, *), variant.contains("glass") {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.maskImage = roundedMask(cornerRadius)
    content.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        content.topAnchor.constraint(equalTo: effect.topAnchor),
        content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    return effect
}

private func roundedMask(_ r: CGFloat) -> NSImage {
    let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
    let img = NSImage(size: size, flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var query = ""
    @Published var typeFilter: ClipKind?
    @Published var appFilter: String?
    @Published var cursorID: UUID?
    @Published var selectedIDs: Set<UUID> = []
    @Published var commandHeld = false
    @Published var focusToken = 0
    @Published var openedAt = Date()
    @Published var renamingItemID: UUID?
    @Published var revealed = false
    /// The search field is expanded (by clicking the magnifier or by typing).
    @Published var searchOpen = false
    @Published var showAccessNotice = false
    @Published var flash: Flash?
    /// Shown after the user moves or resizes the panel.
    @Published var placementPrompt = false
    /// Cards grow and shrink with the panel's height.
    @Published var cardSize: CGSize = PanelStyle.card
    /// Bumped every time the panel opens, so the list starts again from the top.
    @Published var listToken = 0
    /// Vertical layout: docked to the side, cards stacked top to bottom.
    @Published var vertical = Prefs.shared.verticalLayout
    /// Cards side by side in the vertical panel (one when only one fits).
    @Published var columns = 1
    /// Clips as cards or as a list, and the cards' shape (Settings).
    @Published var cardFormat = Prefs.shared.cardFormat
    @Published var cardShape = Prefs.shared.cardShape
    /// Pinned: the panel stays exactly where it is, in the same shape, until it is unpinned.
    @Published var pinned = false
    var anchorID: UUID?

    struct Flash: Equatable {
        let id: UUID
        let message: String
        let symbol: String
        let token = UUID()
    }

    var isRenaming: Bool { renamingItemID != nil }

    /// Cards wide and short enough to put the picture beside the text.
    var sideMedia: Bool { CardStyle.sideMedia(shape: cardShape, vertical: vertical) }
    /// Cards that fill the panel in the original way: sized by the layout rather than a chosen shape.
    var automaticCards: Bool { cardShape == .automatic }

    /// Hides the cards for the next entrance *without* animating, so cards that are
    /// already showing never visibly fade out and back in.
    func resetReveal() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { revealed = false }
    }

    func select(_ id: UUID?) {
        cursorID = id
        anchorID = id
        selectedIDs = id.map { [$0] } ?? []
    }
}

/// The bottom-of-screen panel: window management and keyboard handling.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: KeyPanel
    private unowned let core: AppCore
    private var monitor: Any?
    private var generation = 0
    var suppressHide = false
    /// Click count and modifiers of the most recent mouse-down in the panel.
    private(set) var lastClick: (count: Int, flags: NSEvent.ModifierFlags) = (1, [])

    /// Width of the invisible resize border around the visible panel (the window is this much bigger on every side).
    static let margin = PanelFrameView.margin
    static let height: CGFloat = 384
    // Sizes below are for the visible panel. Wide enough for every button in the top row (search,
    // title, stack, colour picker, layout, pin, menu); the height is capped so cards stay a sensible size.
    static let minSize = NSSize(width: 680, height: 340)
    static let maxHeight: CGFloat = 464
    /// Horizontal layout: the panel is always wider than tall (height / width stays within this).
    static let horizontalAspect: ClosedRange<CGFloat> = 0.2...0.62
    /// Vertical layout.
    static let verticalWidth: CGFloat = 420
    static let verticalMinSize = NSSize(width: 400, height: 540)
    static let verticalMaxWidth: CGFloat = 600
    /// Vertical layout: always taller than wide (height / width).
    static let verticalAspect: ClosedRange<CGFloat> = 1.34...4
    /// Everything in the panel that isn't a card: top bar, day label, padding, action bar.
    static let chromeHeight: CGFloat = 161

    /// Where an in-flight smooth wheel scroll is heading.
    private var scrollTarget: CGFloat?
    /// "Just for now": kept until the panel closes.
    private var sessionFrame: NSRect?
    /// Where the panel was when it was pinned; it comes back to exactly this frame.
    private(set) var pinnedFrame: NSRect?
    /// The self-test always uses the default placement.
    static var useSavedPlacement = true

    init(core: AppCore) {
        self.core = core
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: Self.height),
                         styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()
        panel.level = WindowLevels.overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self

        let host = FirstMouseHostingView(rootView: PanelRoot(store: core.store, model: core.model, prefs: Prefs.shared, core: core))
        host.sizingOptions = []
        let frameView = PanelFrameView(content: makeGlassContainer(host, cornerRadius: PanelStyle.panelRadius))
        frameView.onBegin = { [weak self] in self?.beginPlacementChange() }
        frameView.onEnd = { [weak self] in self?.endPlacementChange() }
        frameView.limits = { [weak self] window in
            self?.limits(on: window?.screen) ?? Limits(min: Self.minSize, max: NSSize(width: 4000, height: Self.maxHeight), aspect: Self.horizontalAspect)
        }
        frameView.isLocked = { [weak self] in self?.core.model.pinned ?? false }
        panel.contentView = frameView

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel, .leftMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .leftMouseDown {
                // SwiftUI runs tap handlers after the event, so remember the click details now.
                if e.window === self.panel { self.lastClick = (e.clickCount, e.modifierFlags) }
                return e
            }
            guard self.panel.isKeyWindow else { return e }
            return self.handle(e)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if isVisible {
            // A pinned panel never goes away on its own: the shortcut just brings it to the front.
            if core.model.pinned { panel.makeKey(); core.model.focusToken += 1 } else { hide() }
        } else {
            show()
        }
    }

    /// Pins the panel exactly where it is (and in the same shape) until it is unpinned: it stays
    /// when you click elsewhere, can't be moved or resized, and ignores Esc and the shortcut.
    func setPinned(_ on: Bool) {
        let model = core.model
        guard model.pinned != on else { return }
        if on {
            guard panel.isVisible else { return }
            model.placementPrompt = false
            pinnedFrame = panel.frame
            withAnimation(PanelStyle.quick) { model.pinned = true }
        } else {
            pinnedFrame = nil
            withAnimation(PanelStyle.quick) { model.pinned = false }
        }
        (panel.contentView as? PanelFrameView)?.lockChanged()
        panel.makeKey()
        core.model.focusToken += 1
    }

    func show() {
        // Already open and pinned: nothing to rearrange, just bring it forward.
        if core.model.pinned && panel.isVisible { panel.makeKey(); core.model.focusToken += 1; return }
        generation += 1
        let model = core.model
        model.openedAt = Date()
        NotificationCenter.default.post(name: .copybookPanelOpened, object: nil)
        model.listToken += 1
        model.query = ""
        model.typeFilter = nil
        model.appFilter = nil
        model.renamingItemID = nil
        model.commandHeld = false
        model.flash = nil
        model.searchOpen = false
        model.resetReveal()
        model.select(core.visibleItems().first?.id)
        model.vertical = Prefs.shared.verticalLayout
        model.cardFormat = Prefs.shared.cardFormat
        model.cardShape = Prefs.shared.cardShape

        panel.sharingType = Prefs.shared.showDuringScreenSharing ? .readOnly : .none
        let target = targetFrame()
        if model.pinned { pinnedFrame = target }
        updateCardSize(for: visibleSize(of: target))
        model.placementPrompt = false
        let start = target.offsetBy(dx: model.vertical ? 36 : 0, dy: model.vertical ? 0 : -36)

        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        model.focusToken += 1
        model.showAccessNotice = false
        core.stack.reposition()
        DispatchQueue.main.async { model.revealed = true }
    }

    /// Hides the panel. A pinned panel stays unless `force` is set (used for deleting everything, and
    /// while the colour picker needs the screen clear).
    func hide(animated: Bool = true, force: Bool = false) {
        guard panel.isVisible else { return }
        if core.model.pinned && !force { return }
        generation += 1
        let gen = generation
        core.preview.hide()
        core.flushPendingTouches()
        sessionFrame = nil
        core.model.placementPrompt = false
        core.model.renamingItemID = nil
        guard animated else { panel.orderOut(nil); core.model.resetReveal(); return }
        let end = core.model.vertical ? panel.frame.offsetBy(dx: 28, dy: 0) : panel.frame.offsetBy(dx: 0, dy: -28)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel.orderOut(nil)
                self.core.model.resetReveal()
            }
        })
    }

    // MARK: Placement

    func defaultFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let inset: CGFloat = 10
        let m = Self.margin
        if core.model.vertical {
            // Docked to the right edge, full height.
            let w = min(Self.verticalWidth, vf.width - inset * 2)
            return NSRect(x: vf.maxX - inset - w - m, y: vf.minY + inset - m, width: w + m * 2, height: vf.height - inset * 2 + m * 2)
        }
        // A card shape with a narrow range of heights may need a shorter or taller bar than the usual one.
        let lim = limits(on: screen)
        var wanted = Self.height
        if core.model.cardFormat == .cards, let card = CardStyle.preferredHeight(for: core.model.cardShape) { wanted = Self.chromeHeight + card }
        let h = min(max(wanted, lim.min.height), lim.max.height)
        return NSRect(x: vf.minX + inset - m, y: vf.minY + inset - m, width: vf.width - inset * 2 + m * 2, height: h + m * 2)
    }

    private var mouseScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// "Just for now" placement, else the saved one (if it's still mostly on a screen), else the default.
    func targetFrame() -> NSRect {
        if core.model.pinned, let f = pinnedFrame { return f }
        if let f = sessionFrame { return clamped(f) }
        if Self.useSavedPlacement, let saved = core.model.vertical ? Prefs.shared.panelFrameVertical : Prefs.shared.panelFrame,
           NSScreen.screens.contains(where: { s in
               let i = s.visibleFrame.intersection(saved)
               return i.width * i.height > saved.width * saved.height * 0.6
           }) {
            return clamped(saved)
        }
        return defaultFrame(on: mouseScreen)
    }

    /// A frame brought within the current size limits (a size saved by an older version, say), keeping
    /// its top-left corner and staying on screen.
    func clamped(_ f: NSRect) -> NSRect {
        let m = Self.margin
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main
        let lim = limits(on: screen)
        let v = Self.constrain(CGSize(width: f.width - 2 * m, height: f.height - 2 * m), limits: lim, changesWidth: true, changesHeight: true)
        // A bar along the bottom keeps its bottom edge where it was; the side panel keeps its top.
        let bottom = !core.model.vertical
        var out = NSRect(x: f.minX, y: bottom ? f.minY : f.maxY - (v.height + 2 * m), width: v.width + 2 * m, height: v.height + 2 * m)
        if let vf = screen?.visibleFrame {
            out.origin.x = min(max(out.minX, vf.minX - m), vf.maxX + m - out.width)
            out.origin.y = min(max(out.minY, vf.minY - m), vf.maxY + m - out.height)
        }
        return out
    }

    func visibleSize(of windowFrame: NSRect) -> CGSize {
        CGSize(width: windowFrame.width - Self.margin * 2, height: windowFrame.height - Self.margin * 2)
    }

    /// Horizontal: cards grow and shrink with the panel's height. Vertical: cards fill its width.
    /// Either way they keep the shape chosen in Settings.
    func updateCardSize(for panel: CGSize) {
        let model = core.model
        let l = model.cardFormat == .list
            ? CardStyle.listLayout(vertical: model.vertical, panel: panel, rowHeight: PanelStyle.listRowHeight,
                                   inset: model.vertical ? PanelStyle.verticalInset : CardStrip.leading)
            : CardStyle.layout(shape: model.cardShape, vertical: model.vertical, panel: panel, chrome: Self.chromeHeight,
                               inset: PanelStyle.verticalInset, verticalHeight: PanelStyle.verticalCardHeight)
        if model.cardSize != l.size { model.cardSize = l.size }
        if model.columns != l.columns { model.columns = l.columns }
    }

    func windowDidResize(_ notification: Notification) { updateCardSize(for: visibleFrame.size) }

    struct Limits {
        var min: NSSize
        var max: NSSize
        /// Allowed height / width.
        var aspect: ClosedRange<CGFloat>
    }

    /// Smallest and largest visible size for the current layout on a screen.
    func limits(on screen: NSScreen?) -> Limits {
        let vf = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        if core.model.vertical {
            return Limits(min: Self.verticalMinSize, max: NSSize(width: min(Self.verticalMaxWidth, vf.width), height: vf.height), aspect: Self.verticalAspect)
        }
        var minSize = Self.minSize, maxHeight = Self.maxHeight
        if core.model.cardFormat == .cards, let range = CardStyle.heightRange(for: core.model.cardShape) {
            minSize.height = max(Self.minSize.height, Self.chromeHeight + range.lowerBound)
            maxHeight = max(minSize.height, min(Self.chromeHeight + range.upperBound, Self.maxHeight + (CardStyle.maxUprightHeight - CardStyle.maxHeight)))
        }
        return Limits(min: minSize, max: NSSize(width: vf.width, height: maxHeight), aspect: Self.horizontalAspect)
    }

    /// Brings a proposed visible size inside the limits: within the min and max, and in the right shape
    /// (wider than tall, or taller than wide). When only one side is being dragged, that side gives way
    /// to the shape rule; when both are, the height does.
    static func constrain(_ size: CGSize, limits l: Limits, changesWidth: Bool, changesHeight: Bool) -> CGSize {
        func clampW(_ v: CGFloat) -> CGFloat { Swift.min(Swift.max(v, l.min.width), l.max.width) }
        func clampH(_ v: CGFloat) -> CGFloat { Swift.min(Swift.max(v, l.min.height), l.max.height) }
        var w = clampW(size.width), h = clampH(size.height)
        for _ in 0..<2 {
            if h > w * l.aspect.upperBound {
                if changesWidth && !changesHeight { w = clampW(h / l.aspect.upperBound) } else { h = clampH(w * l.aspect.upperBound) }
            }
            if h < w * l.aspect.lowerBound {
                if changesHeight && !changesWidth { h = clampH(w * l.aspect.lowerBound) } else { w = clampW(h / l.aspect.lowerBound) }
            }
        }
        return CGSize(width: w, height: h)
    }

    /// The visible rounded panel (the window also contains the invisible resize border).
    var visibleFrame: NSRect { panel.frame.insetBy(dx: Self.margin, dy: Self.margin) }

    /// Called by the grab handle and edges when a drag begins.
    func beginPlacementChange() {
        core.preview.hide()
        core.model.placementPrompt = false
    }

    /// Called when a move or resize ends: blur the panel and ask what to keep.
    func endPlacementChange() {
        panel.invalidateShadow()
        core.stack.reposition()
        withAnimation(PanelStyle.spring) { core.model.placementPrompt = true }
    }

    func keepPlacement(always: Bool) {
        if always {
            if core.model.vertical { Prefs.shared.panelFrameVertical = panel.frame } else { Prefs.shared.panelFrame = panel.frame }
            sessionFrame = nil
        } else {
            sessionFrame = panel.frame
        }
        withAnimation(PanelStyle.spring) { core.model.placementPrompt = false }
        panel.makeKey()
        core.model.focusToken += 1
    }

    func resetPlacement() {
        if core.model.vertical { Prefs.shared.panelFrameVertical = nil } else { Prefs.shared.panelFrame = nil }
        sessionFrame = nil
        let target = defaultFrame(on: panel.screen ?? mouseScreen)
        withAnimation(PanelStyle.spring) { core.model.placementPrompt = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(target, display: true)
        }
        updateCardSize(for: visibleSize(of: target))
        core.stack.reposition()
        panel.makeKey()
    }

    /// True while the panel is fading out for a layout switch.
    private var layoutFading = false

    /// The layout preference changed (panel button or Settings): swap between horizontal and
    /// vertical. The panel fades out, reappears at the new layout's place and its cards fade in.
    /// Flipping again mid-fade is fine: the switch in progress reads the latest preference when
    /// it lands, so the panel always ends up in the layout the setting says.
    func layoutPreferenceChanged() {
        let model = core.model
        if layoutFading { return }
        guard model.vertical != Prefs.shared.verticalLayout else { return }
        sessionFrame = nil
        core.preview.hide()
        model.placementPrompt = false
        guard panel.isVisible else { model.vertical = Prefs.shared.verticalLayout; return }   // takes effect when it next opens
        generation += 1
        let gen = generation
        layoutFading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutFading = false
                guard self.generation == gen, self.panel.isVisible else { return }
                let want = Prefs.shared.verticalLayout
                if model.vertical == want {
                    // Flipped back to where it was during the fade: just fade in again.
                    NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; self.panel.animator().alphaValue = 1 }
                    return
                }
                model.resetReveal()
                model.vertical = want
                self.pinnedFrame = nil   // the new layout has its own place
                let target = self.targetFrame()
                self.updateCardSize(for: self.visibleSize(of: target))
                self.panel.setFrame(target.offsetBy(dx: want ? 36 : 0, dy: want ? 0 : -36), display: true)
                self.panel.invalidateShadow()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                    self.panel.animator().setFrame(target, display: true)
                    self.panel.animator().alphaValue = 1
                }
                self.panel.makeKey()
                if model.pinned { self.pinnedFrame = target }
                self.core.stack.reposition()
                model.focusToken += 1
                DispatchQueue.main.async { model.revealed = true }
                // Flipped again while the panel was being rearranged: carry on to the latest.
                if Prefs.shared.verticalLayout != want { self.layoutPreferenceChanged() }
            }
        })
    }

    /// The card format or shape changed in Settings. The panel re-fits (a shape may allow a different
    /// range of heights), the cards take their new size and fade back in from the top.
    func cardStyleChanged() {
        let model = core.model
        let prefs = Prefs.shared
        guard model.cardFormat != prefs.cardFormat || model.cardShape != prefs.cardShape else { return }
        guard panel.isVisible else {
            model.cardFormat = prefs.cardFormat; model.cardShape = prefs.cardShape   // takes effect when it next opens
            return
        }
        model.placementPrompt = false
        core.preview.hide()
        model.resetReveal()
        model.cardFormat = prefs.cardFormat
        model.cardShape = prefs.cardShape
        var target = panel.frame
        // A pinned panel keeps its exact frame; otherwise it moves into the new shape's limits.
        if !model.pinned {
            var wanted = panel.frame
            if !model.vertical {
                // A new shape starts the bar at the height that gives it a good size (kept to its bottom edge).
                var card = CardStyle.preferredHeight(for: model.cardShape)
                if prefs.cardFormat == .list || card == nil { card = Self.height - Self.chromeHeight }
                wanted.size.height = Self.chromeHeight + (card ?? 0) + Self.margin * 2
            }
            target = clamped(wanted)
            if sessionFrame != nil { sessionFrame = target }
        }
        if target != panel.frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(target, display: true)
            }
            panel.invalidateShadow()
        }
        updateCardSize(for: visibleSize(of: target))
        model.listToken += 1   // a fresh list, back at the top
        core.stack.reposition()
        DispatchQueue.main.async { model.revealed = true }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressHide, !CardInteractionView.isDragging else { return }
        if core.model.pinned {
            // Stays open. Clips copied while it had focus can move to the top now that it's safe.
            core.flushPendingTouches()
            return
        }
        hide()
    }

    /// Runs a modal (alert, open panel) without the panel auto-hiding underneath it.
    func withModal<T>(_ body: () -> T) -> T {
        suppressHide = true
        NSApp.activate(ignoringOtherApps: true)
        let result = body()
        suppressHide = false
        panel.makeKey()
        return result
    }

    // MARK: Keyboard

    private static let numberKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// How far up or down moves the cursor: a whole row when cards sit side by side, otherwise one clip.
    private var rowStep: Int {
        let m = core.model
        return m.vertical || m.cardFormat == .list ? max(1, m.columns) : 1
    }

    func handle(_ e: NSEvent) -> NSEvent? {
        let model = core.model
        if e.type == .flagsChanged {
            model.commandHeld = e.modifierFlags.contains(.command)
            return e
        }
        if e.type == .scrollWheel { return smoothWheel(e) }

        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(e.keyCode)

        if model.placementPrompt {
            if code == kVK_Escape { keepPlacement(always: false) }
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter { keepPlacement(always: true) }
            return nil
        }

        if model.isRenaming {
            if code == kVK_Escape {
                model.renamingItemID = nil
                        model.focusToken += 1
                return nil
            }
            return e
        }

        switch code {
        case kVK_Escape:
            if !model.query.isEmpty || model.typeFilter != nil || model.appFilter != nil {
                model.query = ""; model.typeFilter = nil; model.appFilter = nil
            } else if model.searchOpen {
                model.searchOpen = false
            } else if core.preview.isVisible {
                core.preview.hide()
            } else if !model.pinned {
                hide()
            }
            return nil
        case kVK_LeftArrow:
            core.moveCursor(-1, extend: flags.contains(.shift), toEnd: flags.contains(.command))
            return nil
        case kVK_UpArrow:
            core.moveCursor(-rowStep, extend: flags.contains(.shift), toEnd: flags.contains(.command))
            return nil
        case kVK_RightArrow:
            core.moveCursor(1, extend: flags.contains(.shift), toEnd: flags.contains(.command))
            return nil
        case kVK_DownArrow:
            core.moveCursor(rowStep, extend: flags.contains(.shift), toEnd: flags.contains(.command))
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            core.pasteSelection(plain: flags.contains(.shift) || flags.contains(.option))
            return nil
        case kVK_Space where model.query.isEmpty && flags.isEmpty:
            core.togglePreview()
            return nil
        case kVK_Delete where flags.contains(.command), kVK_ForwardDelete where model.query.isEmpty:
            core.deleteSelection()
            return nil
        default:
            break
        }

        if flags == .command {
            if let idx = Self.numberKeys.firstIndex(of: code) {
                core.quickPaste(index: idx)
                return nil
            }
            switch code {
            case kVK_ANSI_C: core.copySelection(); return nil
            case kVK_ANSI_F: model.searchOpen = true; model.focusToken += 1; return nil
            case kVK_ANSI_E: core.editCursor(); return nil
            case kVK_ANSI_Comma: core.openSettings(); return nil
            default: break
            }
        }
        if flags == [.command, .shift], code == kVK_ANSI_C {
            core.addSelectionToStack()
            return nil
        }
        return e
    }

    /// Mouse wheels move in coarse notches; turn each notch into a smooth, eased glide of
    /// the card strip. Trackpads and Magic Mouse already scroll smoothly and pass through.
    func smoothWheel(_ e: NSEvent) -> NSEvent? {
        guard !e.hasPreciseScrollingDeltas else { return e }
        let raw = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : e.scrollingDeltaX
        guard raw != 0, let sv = cardScrollView(), let doc = sv.documentView else { return e }
        let clip = sv.contentView
        let vertical = core.model.vertical
        // The scrollable range includes the scroll view's own insets (safe-area padding).
        let insets = sv.contentInsets
        let lo = vertical ? -insets.top : -insets.left
        let hi = vertical ? doc.frame.height - clip.bounds.height + insets.bottom : doc.frame.width - clip.bounds.width + insets.right
        let base = scrollTarget ?? (vertical ? clip.bounds.origin.y : clip.bounds.origin.x)
        // A flipped document grows downward; wheel-up must still move toward the top.
        let direction: CGFloat = vertical && !doc.isFlipped ? 1 : -1
        let target = min(max(base + direction * raw * 72, lo), max(lo, hi))
        scrollTarget = target
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(vertical ? NSPoint(x: clip.bounds.origin.x, y: target) : NSPoint(x: target, y: clip.bounds.origin.y))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                sv.reflectScrolledClipView(clip)
                if self?.scrollTarget == target { self?.scrollTarget = nil }
            }
        })
        return nil
    }

    /// The scroll view that holds the cards (horizontal, or vertical in the vertical layout).
    func cardScrollView() -> NSScrollView? {
        var queue: [NSView] = panel.contentView.map { [$0] } ?? []
        let vertical = core.model.vertical
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let sv = v as? NSScrollView, let doc = sv.documentView,
               vertical ? doc.frame.height + sv.contentInsets.top + sv.contentInsets.bottom > sv.contentView.bounds.height + 1
                        : doc.frame.width > sv.contentView.bounds.width + 1 {
                return sv
            }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }
}
