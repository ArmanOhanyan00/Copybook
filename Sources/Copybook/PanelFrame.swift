import AppKit

/// The panel window's content view. The visible rounded panel sits inset by `margin`, and the
/// margin around it is an invisible resize border owned by this view. Because it lives in the
/// panel's own window (the key window), the cursor and mouse events behave exactly as they do
/// for the panel itself, instead of depending on a second window that never becomes key.
final class PanelFrameView: NSView {
    static let margin: CGFloat = 10
    /// How far along an edge, from a corner, a grab counts as a corner grab.
    private static let corner: CGFloat = 26

    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    /// Smallest and largest visible size, and the allowed shape, for the current layout and screen.
    var limits: (NSWindow?) -> PanelController.Limits = { _ in
        PanelController.Limits(min: NSSize(width: 680, height: 340), max: NSSize(width: 4000, height: 464), aspect: 0.2...0.62)
    }
    /// While the panel is pinned it can't be moved or resized, so the border does nothing.
    var isLocked: () -> Bool = { false }

    func lockChanged() { window?.invalidateCursorRects(for: self) }

    private let content: NSView
    private var mode: WindowDragMode = .bottom
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    private var changed = false
    /// True only for a drag that began in the border. Clicks on empty parts of the panel
    /// bubble up here too, and must not resize anything.
    private var active = false
    private var pendingFrame: NSRect?

    init(content: NSView) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: 1200, height: 400))
        content.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var visible: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    // MARK: Hit testing and drawing

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The band around the rounded panel: inside the window, outside the rounded outline, and
    /// within `margin` of it (so it follows the corners instead of squaring them off).
    private var ring: NSBezierPath {
        let r = PanelStyle.panelRadius, m = Self.margin
        let path = NSBezierPath(roundedRect: bounds, xRadius: r + m, yRadius: r + m)
        // The band reaches 1 pt inside the visible edge, matching the cursor rects, so the cursor
        // and the grab always agree about where the edge is.
        path.append(NSBezierPath(roundedRect: visible.insetBy(dx: 1, dy: 1), xRadius: r - 1, yRadius: r - 1))
        path.windingRule = .evenOdd
        return path
    }

    private func inMargin(_ p: NSPoint) -> Bool { ring.contains(p) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return inMargin(p) ? self : super.hitTest(point)
    }

    /// macOS passes clicks through fully transparent pixels, so the border carries an alpha too
    /// faint to see. It follows the panel's rounded outline (never a square) so the window's
    /// shadow keeps a rounded shape.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 0.012).setFill()
        ring.fill()
    }

    // MARK: Zones and cursors

    private func zone(at p: NSPoint) -> WindowDragMode {
        let v = visible, c = Self.corner
        let nearLeft = p.x < v.minX + c, nearRight = p.x > v.maxX - c
        let nearBottom = p.y < v.minY + c, nearTop = p.y > v.maxY - c
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        // A grab exactly on the visible edge belongs to the nearer side, not the far one.
        let dx = min(abs(p.x - v.minX), abs(p.x - v.maxX)), dy = min(abs(p.y - v.minY), abs(p.y - v.maxY))
        if dy < dx { return p.y > v.midY ? .top : .bottom }
        return p.x < v.midX ? .left : .right
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if isLocked() { return }
        let b = bounds, v = visible, m = Self.margin, c = Self.corner
        func add(_ r: NSRect, _ mode: WindowDragMode) { addCursorRect(r, cursor: WindowDragView.cursor(for: mode)) }
        add(NSRect(x: v.minX + c, y: v.maxY - 1, width: v.width - 2 * c, height: m + 1), .top)
        add(NSRect(x: v.minX + c, y: b.minY, width: v.width - 2 * c, height: m + 2), .bottom)
        add(NSRect(x: b.minX, y: v.minY + c, width: m + 2, height: v.height - 2 * c), .left)
        add(NSRect(x: v.maxX - 1, y: v.minY + c, width: m + 1, height: v.height - 2 * c), .right)
        add(NSRect(x: b.minX, y: v.maxY, width: m + c, height: m), .topLeft)
        add(NSRect(x: b.minX, y: v.maxY - c, width: m, height: c), .topLeft)
        add(NSRect(x: v.maxX - c, y: v.maxY, width: m + c, height: m), .topRight)
        add(NSRect(x: v.maxX, y: v.maxY - c, width: m, height: c), .topRight)
        add(NSRect(x: b.minX, y: b.minY, width: m + c, height: m), .bottomLeft)
        add(NSRect(x: b.minX, y: v.minY, width: m, height: c), .bottomLeft)
        add(NSRect(x: v.maxX - c, y: b.minY, width: m + c, height: m), .bottomRight)
        add(NSRect(x: v.maxX, y: v.minY, width: m, height: c), .bottomRight)
    }

    /// Cursor rects alone can lag behind a fast pointer; set the cursor directly too.
    override func mouseMoved(with event: NSEvent) {
        if isLocked() { return }
        let p = convert(event.locationInWindow, from: nil)
        if inMargin(p) { WindowDragView.cursor(for: zone(at: p)).set() }
    }

    // MARK: Resizing

    private static let debug = ProcessInfo.processInfo.environment["COPYBOOK_DEBUG_FRAME"] != nil

    override func mouseDown(with event: NSEvent) {
        if Self.debug {
            let p = convert(event.locationInWindow, from: nil)
            FileHandle.standardError.write(Data("down \(p) bounds \(bounds) inMargin \(inMargin(p)) zone \(zone(at: p)) window \(window?.frame ?? .zero)\n".utf8))
        }
        active = false
        guard !isLocked(), let window, inMargin(convert(event.locationInWindow, from: nil)) else { return }
        active = true
        mode = zone(at: convert(event.locationInWindow, from: nil))
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
        changed = false
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard active, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        if !changed && hypot(dx, dy) < 2 { return }
        changed = true
        if Self.debug { FileHandle.standardError.write(Data("drag mode \(mode) d=(\(dx),\(dy)) start \(startFrame)\n".utf8)) }

        let m2 = Self.margin * 2
        let lim = limits(window)
        let growsRight = [.right, .topRight, .bottomRight].contains(mode), growsLeft = [.left, .topLeft, .bottomLeft].contains(mode)
        let growsUp = [.top, .topLeft, .topRight].contains(mode), growsDown = [.bottom, .bottomLeft, .bottomRight].contains(mode)
        var vis = CGSize(width: startFrame.width - m2, height: startFrame.height - m2)
        if growsRight { vis.width += dx }
        if growsLeft { vis.width -= dx }
        if growsUp { vis.height += dy }
        if growsDown { vis.height -= dy }
        // Within the size limits and in the right shape (wider than tall, or taller than wide).
        vis = PanelController.constrain(vis, limits: lim, changesWidth: growsLeft || growsRight, changesHeight: growsUp || growsDown)

        var f = startFrame
        f.size = NSSize(width: vis.width + m2, height: vis.height + m2)
        if growsLeft { f.origin.x = startFrame.maxX - f.width }
        if growsDown { f.origin.y = startFrame.maxY - f.height }
        // Once per run-loop pass: a fast mouse sends far more events than there are frames.
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
        if changed { onEnd() }
    }
}
