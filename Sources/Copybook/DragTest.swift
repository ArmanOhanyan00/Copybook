import AppKit

/// Debug aid (COPYBOOK_DRAGTEST=<dir>): drags cards into the frontmost TextEdit window
/// several times in a row with real mouse events, and logs how each drag ended.
/// Needs Accessibility permission and an open TextEdit document.
@MainActor
final class DragTest {
    let dir: String
    var log: [String] = []
    init(dir: String) { self.dir = dir }

    func run() {
        let core = AppCore.shared
        PanelController.useSavedPlacement = false
        CardInteractionView.onDragEnded = { [weak self] op, pt in
            MainActor.assumeIsolated {
                self?.log.append("  drag ended: operation \(op.rawValue) at \(Int(pt.x)),\(Int(pt.y)) · panel visible \(core.panelController.isVisible) key \(core.panelController.panel.isKeyWindow)")
            }
        }
        log.append("trusted: \(AXIsProcessTrusted())")
        if ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_RESIZE"] != nil { resizeTest(); return }
        let attempts = Int(ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_N"] ?? "4") ?? 4
        step(0, of: attempts)
    }

    private var targetPoint: CGPoint? {
        if let at = ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_AT"]?.split(separator: ",").compactMap({ Double($0) }), at.count == 2 {
            return CGPoint(x: at[0], y: at[1])
        }
        guard let c = textEditCenter() else { return nil }
        // Optional offset so the drop lands in a text box rather than on page chrome.
        let dy = CGFloat(Double(ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_DY"] ?? "0") ?? 0)
        return CGPoint(x: c.x, y: c.y + dy)
    }

    private func step(_ i: Int, of n: Int) {
        let core = AppCore.shared
        guard i < n else { finish(); return }
        if !core.panelController.isVisible {
            log.append("attempt \(i + 1): panel was hidden, reopening")
            core.panelController.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            guard let target = targetPoint else { log.append("no TextEdit window"); finish(); return }
            let panel = core.panelController.panel
            let size = core.model.cardSize
            let primary = NSScreen.screens[0].frame.height
            let cards = (ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_CARDS"] ?? "0,1").split(separator: ",").compactMap { Int($0) }
            let cardIndex = cards[i % cards.count]
            // Cards that start a new day sit 14 pt further right.
            let items = core.visibleItems()
            let cal = Calendar.current
            var gaps: CGFloat = 0
            for k in 1...max(1, cardIndex) where k <= cardIndex && !cal.isDate(items[k].date, inSameDayAs: items[k - 1].date) { gaps += 14 }
            let wx = CardStrip.leading + size.width / 2 + CGFloat(cardIndex) * (size.width + PanelStyle.cardSpacing) + gaps
            let wy = CardStrip.bottom + size.height / 2
            let start = CGPoint(x: panel.frame.minX + PanelController.margin + wx, y: primary - (panel.frame.minY + PanelController.margin + wy))
            log.append("attempt \(i + 1): card \(cardIndex) \(core.visibleItems()[cardIndex].kind.label) · panel key \(panel.isKeyWindow) · front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            DispatchQueue.global().async {
                Self.drag(from: start, to: target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated {
                        self.log.append("  after: panel visible \(core.panelController.isVisible) · front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                        self.step(i + 1, of: n)
                    }
                }
            }
        }
    }

    /// Grabs the panel's edges and a rounded corner with the real mouse.
    private func resizeTest() {
        let pc = AppCore.shared.panelController
        pc.show()
        let primary = NSScreen.screens[0].frame.height
        func g(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primary - p.y) }
        /// A point on the border around a rounded corner of the visible panel (middle of the band).
        func arc(_ v: NSRect, _ corner: WindowDragMode) -> NSPoint {
            let r = PanelStyle.panelRadius, d = (r + PanelController.margin / 2) / 2.0.squareRoot()
            switch corner {
            case .topLeft: return NSPoint(x: v.minX + r - d, y: v.maxY - r + d)
            case .topRight: return NSPoint(x: v.maxX - r + d, y: v.maxY - r + d)
            case .bottomLeft: return NSPoint(x: v.minX + r - d, y: v.minY + r - d)
            default: return NSPoint(x: v.maxX - r + d, y: v.minY + r - d)
            }
        }
        // (label, grab point from the visible panel frame, movement)
        let allCases: [(String, (NSRect) -> NSPoint, CGVector)] = [
            ("top edge 4pt outside", { NSPoint(x: $0.midX - 300, y: $0.maxY + 4) }, CGVector(dx: 0, dy: 60)),
            ("right edge 3pt outside", { NSPoint(x: $0.maxX + 3, y: $0.midY) }, CGVector(dx: -100, dy: 0)),
            ("bottom-left corner, in the border", { arc($0, .bottomLeft) }, CGVector(dx: 80, dy: 40)),
            ("bottom-right corner, in the border", { arc($0, .bottomRight) }, CGVector(dx: -80, dy: 40)),
            ("top-left corner, in the border", { arc($0, .topLeft) }, CGVector(dx: 60, dy: -30)),
            ("empty panel area must not resize", { NSPoint(x: $0.minX + 40, y: $0.minY + 12) }, CGVector(dx: 120, dy: 0)),
            ("top edge 2pt outside", { NSPoint(x: $0.midX - 300, y: $0.maxY + 2) }, CGVector(dx: 0, dy: 120)),
            ("top-right corner", { arc($0, .topRight) }, CGVector(dx: -150, dy: -60)),
            ("left edge 3pt outside", { NSPoint(x: $0.minX - 3, y: $0.midY) }, CGVector(dx: 200, dy: 0)),
            ("move grip", { NSPoint(x: $0.midX, y: $0.maxY - 7) }, CGVector(dx: 0, dy: 80)),
            ("strip far from the pill moves it", { NSPoint(x: $0.minX + 160, y: $0.maxY - 10) }, CGVector(dx: 90, dy: 0)),
            ("gap below the strip must not move", { NSPoint(x: $0.minX + 160, y: $0.maxY - (PanelStyle.gripStrip + 3)) }, CGVector(dx: 90, dy: 0)),
            ("search field must not move", { NSPoint(x: $0.minX + 160, y: $0.maxY - (PanelStyle.topInset + 30)) }, CGVector(dx: 90, dy: 0)),
        ]
        let verticalCases: [(String, (NSRect) -> NSPoint, CGVector)] = [
            ("V left edge 3pt outside (widen)", { NSPoint(x: $0.minX - 3, y: $0.midY) }, CGVector(dx: -80, dy: 0)),
            ("V right edge 3pt outside (narrow)", { NSPoint(x: $0.maxX + 3, y: $0.midY) }, CGVector(dx: -50, dy: 0)),
            ("V top-left corner (widen, shorten)", { arc($0, .topLeft) }, CGVector(dx: -40, dy: -100)),
            ("V bottom-left corner (widen, shorten)", { arc($0, .bottomLeft) }, CGVector(dx: -30, dy: 80)),
            ("V bottom edge 2pt outside (taller)", { NSPoint(x: $0.midX - 40, y: $0.minY - 2) }, CGVector(dx: 0, dy: -60)),
            ("V empty area must not resize", { NSPoint(x: $0.minX + 60, y: $0.midY) }, CGVector(dx: -120, dy: 0)),
            ("V move grip (left)", { NSPoint(x: $0.midX, y: $0.maxY - 7) }, CGVector(dx: -120, dy: 0)),
            ("V strip far from the pill moves it", { NSPoint(x: $0.minX + 70, y: $0.maxY - 10) }, CGVector(dx: -60, dy: 0)),
            ("V gap below the strip must not move", { NSPoint(x: $0.minX + 70, y: $0.maxY - (PanelStyle.gripStrip + 3)) }, CGVector(dx: -60, dy: 0)),
            ("V search field must not move", { NSPoint(x: $0.minX + 70, y: $0.maxY - (PanelStyle.topInset + 30)) }, CGVector(dx: -60, dy: 0)),
        ]
        let only = ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_ONLY"]
        let base = ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_VERTICAL"] != nil ? verticalCases : allCases
        let cases = only.map { o in o.split(separator: "|").flatMap { part in base.filter { $0.0.contains(part) } } } ?? base
        func run(_ i: Int) {
            guard i < cases.count else { finish(); return }
            let (label, grab, move) = cases[i]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                if AppCore.shared.model.placementPrompt {
                    pc.keepPlacement(always: false)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.9))   // let the prompt finish closing
                }
                let before = pc.panel.frame
                let p = grab(pc.visibleFrame)
                let a = g(p), b = CGPoint(x: a.x + move.dx, y: a.y - move.dy)
                // Which window is on top at the grab point?
                let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let hit = info.first { w in
                    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                    return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!).contains(a)
                        && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
                }
                self.log.append("  grab \(Int(a.x)),\(Int(a.y)) → top window: \(hit?[kCGWindowOwnerName as String] ?? "?") \(hit?[kCGWindowNumber as String] ?? "") layer \(hit?[kCGWindowLayer as String] ?? "") · ring windows: \(pc.panel.childWindows?.map { "\($0.windowNumber) visible \($0.isVisible) \(NSStringFromRect($0.frame))" } ?? [])")
                DispatchQueue.global().async {
                    Self.drag(from: a, to: b)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        MainActor.assumeIsolated {
                            let after = pc.panel.frame
                            self.log.append("\(label): \(NSStringFromRect(before)) → \(NSStringFromRect(after)) · prompt \(AppCore.shared.model.placementPrompt)")
                            run(i + 1)
                        }
                    }
                }
            }
        }
        run(0)
    }

    nonisolated private static func drag(from a: CGPoint, to b: CGPoint) {
        func post(_ type: CGEventType, _ p: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, a); usleep(150_000)
        post(.leftMouseDown, a); usleep(350_000)
        let steps = 60
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            usleep(20_000)
        }
        usleep(300_000)
        post(.leftMouseUp, b)
    }

    private func textEditCenter() -> CGPoint? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let app = ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST_APP"] ?? "TextEdit"
        for w in info where (w[kCGWindowOwnerName as String] as? String) == app && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let x = b["X"], let y = b["Y"],
                  let width = b["Width"], let height = b["Height"], height > 100 else { continue }
            return CGPoint(x: x + width / 2, y: y + height / 2)
        }
        return nil
    }

    private func finish() {
        try? log.joined(separator: "\n").write(toFile: dir + "/dragtest.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

/// Debug aid (COPYBOOK_RESIZETEST=<dir>): times resize steps like an edge drag would make them.
@MainActor
final class ResizeTest {
    let dir: String
    init(dir: String) { self.dir = dir }

    func run() {
        let pc = AppCore.shared.panelController
        PanelController.useSavedPlacement = false
        pc.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            var log: [String] = []
            let start = pc.panel.frame
            for (label, edge) in [("bottom→up (height)", 0), ("top (height+origin)", 1), ("left (width+origin)", 2)] {
                var times: [Double] = []
                for k in 0..<40 {
                    var f = start
                    let d = CGFloat(k) * 4
                    switch edge {
                    case 0: f.size.height += d
                    case 1: f.size.height += d; f.origin.y -= 0
                    default: f.size.width -= d; f.origin.x += d
                    }
                    let t0 = CACurrentMediaTime()
                    pc.panel.setFrame(f, display: true)
                    pc.panel.contentView?.layoutSubtreeIfNeeded()
                    pc.panel.displayIfNeeded()
                    CATransaction.flush()
                    times.append((CACurrentMediaTime() - t0) * 1000)
                }
                pc.panel.setFrame(start, display: true)
                let sorted = times.sorted()
                log.append(String(format: "%@: median %.1f ms · p90 %.1f ms · max %.1f ms", label,
                                  sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last!))
            }
            try? log.joined(separator: "\n").write(toFile: dir + "/resizetest.log", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

/// Debug aid (COPYBOOK_COMPOSITE=<dir>): captures the panel as the window server composites it
/// (glass, shadow and all), which a view snapshot can't show, and crops its corners.
@MainActor
final class CompositeTest {
    let dir: String
    init(dir: String) { self.dir = dir }

    func run() {
        let pc = AppCore.shared.panelController
        PanelController.useSavedPlacement = false
        pc.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            var windows = [pc.panel] + (pc.panel.childWindows ?? [])
            windows = windows.filter { $0.isVisible }
            var log: [String] = []
            for (i, w) in windows.enumerated() {
                let rect = w.frame.insetBy(dx: -40, dy: -40)
                let primary = NSScreen.screens[0].frame.height
                let cg = CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
                guard let img = CGWindowListCreateImage(cg, .optionIncludingWindow, CGWindowID(w.windowNumber), [.bestResolution]) else {
                    log.append("window \(i): capture failed"); continue
                }
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/window\(i).png"))
                log.append("window \(i) \(NSStringFromRect(w.frame)): \(img.width)×\(img.height)")
                if i == 0 {
                    // Pixels just outside the panel's rounded bottom-right corner (inset 40 pt = 80 px).
                    let edge = Int((40 + PanelController.margin) * 2)
                    let r = Int(PanelStyle.panelRadius * 2), cx = img.width - edge - r, cy = img.height - edge - r
                    for d in [1.0, 1.15, 1.3, 1.6, 2.0] {
                        let off = Int(Double(r) * d / 2.0.squareRoot())
                        let px = rep.colorAt(x: cx + off, y: cy + off)
                        log.append(String(format: "  corner probe ×%.2f of radius: alpha %.3f  gray %.3f", d, px?.alphaComponent ?? -1, px?.redComponent ?? -1))
                    }
                }
            }
            try? log.joined(separator: "\n").write(toFile: dir + "/composite.log", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

/// Debug aid (COPYBOOK_EDGETEST=<dir>): drags the right and left edges from points inside and
/// outside the border with the real mouse and reports which grabs resized the panel.
@MainActor
final class EdgeTest {
    let dir: String
    var log: [String] = []
    init(dir: String) { self.dir = dir }

    func run() {
        let pc = AppCore.shared.panelController
        PanelController.useSavedPlacement = false
        pc.show()
        let model = AppCore.shared.model
        // Offsets from the right edge: negative = inside the panel, positive = outside.
        let offsets: [CGFloat] = [-8, -4, -2, -1, 0, 1, 2, 4, 6, 8]
        func run(_ i: Int) {
            guard i < offsets.count else {
                try? log.joined(separator: "\n").write(toFile: dir + "/edgetest.log", atomically: true, encoding: .utf8)
                NSApp.terminate(nil); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [self] in
                if model.placementPrompt { pc.keepPlacement(always: false) }
                // Start each try from the same frame.
                let left = ProcessInfo.processInfo.environment["COPYBOOK_EDGE_SIDE"] == "left"
                let sv = (pc.panel.screen ?? NSScreen.main)!.visibleFrame, mm = PanelController.margin
                let f0 = left ? NSRect(x: sv.maxX - 10 - PanelController.verticalWidth - mm, y: sv.minY + 10 - mm, width: PanelController.verticalWidth + 2 * mm, height: sv.height - 20 + 2 * mm)
                               : NSRect(x: 100, y: 120, width: 1500, height: 370)
                pc.panel.setFrame(f0, display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let primary = NSScreen.screens[0].frame.height
                    let before = pc.panel.frame
                    let off = offsets[i]
                    let a = left ? CGPoint(x: before.minX + PanelController.margin - off, y: primary - before.midY)
                                 : CGPoint(x: before.maxX - PanelController.margin + off, y: primary - before.midY)
                    let b = left ? CGPoint(x: a.x - 80, y: a.y) : CGPoint(x: a.x - 80, y: a.y)
                    DispatchQueue.global().async {
                        func post(_ t: CGEventType, _ p: CGPoint) {
                            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                        }
                        post(.mouseMoved, CGPoint(x: a.x - 30, y: a.y)); usleep(120_000)
                        post(.mouseMoved, a); usleep(350_000)
                        let cursorOK = DispatchQueue.main.sync { MainActor.assumeIsolated { () -> Bool in
                            let cur = NSCursor.currentSystem?.image.tiffRepresentation
                            var known = [NSCursor.resizeLeftRight.image.tiffRepresentation]
                            if #available(macOS 15.0, *) { known.append(NSCursor.frameResize(position: .right, directions: .all).image.tiffRepresentation) }
                            return known.contains { $0 == cur }
                        } }
                        post(.leftMouseDown, a); usleep(200_000)
                        for k in 1...30 { post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / 30, y: a.y)); usleep(15_000) }
                        usleep(200_000); post(.leftMouseUp, b)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            MainActor.assumeIsolated {
                                let w = pc.panel.frame.width
                                self.log.append(String(format: "edge %+3.0f pt: cursor %@ · width %.0f → %.0f · %@", off,
                                                       cursorOK ? "resize " : "normal ", before.width, w, w != before.width ? "RESIZED" : "missed"))
                                run(i + 1)
                            }
                        }
                    }
                }
            }
        }
        run(0)
    }
}

/// Debug aid (COPYBOOK_LAYOUTTEST=<dir>): exercises both layouts hard. Captures the composited
/// window in light and dark, audits card positions and spacing, button overlaps, the Stack
/// and preview placement, resizing limits, keyboard and wheel scrolling, and rapid toggling.
/// Run with COPYBOOK_TEST_DEFAULTS=1 so it never touches the user's saved settings.
@MainActor
final class LayoutTest {
    let dir: String
    var log: [String] = []
    var failures = 0
    let core = AppCore.shared
    var pc: PanelController { core.panelController }
    var m: CGFloat { PanelController.margin }
    init(dir: String) { self.dir = dir }

    func emit(_ line: String) {
        log.append(line)
        // Written as it goes, so a hang shows where it stopped.
        try? (log.joined(separator: "\n") + "\n").write(toFile: dir + "/layouttest.partial.log", atomically: true, encoding: .utf8)
    }
    func check(_ ok: Bool, _ msg: String) {
        emit((ok ? "ok    " : "FAIL  ") + msg)
        if !ok { failures += 1 }
    }
    func note(_ msg: String) { emit("      " + msg) }
    func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    // MARK: Helpers

    func capture(_ name: String) {
        let w = pc.panel
        let rect = w.frame.insetBy(dx: -30, dy: -30)
        let primary = NSScreen.screens[0].frame.height
        let cg = CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
        guard let img = CGWindowListCreateImage(cg, .optionIncludingWindow, CGWindowID(w.windowNumber), [.bestResolution]) else {
            check(false, "capture \(name) failed"); return
        }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func axButtons() async -> [(String, CGRect)] {
        await axAll().filter { [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole].contains($0.role) }.map { ($0.label, $0.frame) }
    }

    func axAll() async -> [(role: String, label: String, frame: CGRect)] {
        let (found, timedOut, visited) = await withCheckedContinuation { (cont: CheckedContinuation<([(role: String, label: String, frame: CGRect)], Bool, Int), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(getpid())
                AXUIElementSetMessagingTimeout(app, 3)
                var found: [(role: String, label: String, frame: CGRect)] = []
                var pending: [AXUIElement] = [app]
                var visited = 0
                let deadline = Date().addingTimeInterval(8)
                while let el = pending.popLast(), visited < 8000, Date() < deadline {
                    visited += 1
                    AXUIElementSetMessagingTimeout(el, 1)
                    let role = SelfTest.attr(el, kAXRoleAttribute) as? String ?? ""
                    let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap { SelfTest.attr(el, $0) as? String }.first { !$0.isEmpty } ?? ""
                    if [kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole, "AXSwitch", kAXStaticTextRole].contains(role) {
                        var origin = CGPoint.zero, size = CGSize.zero
                        if let p = SelfTest.attr(el, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
                        if let z = SelfTest.attr(el, kAXSizeAttribute) { AXValueGetValue(z as! AXValue, .cgSize, &size) }
                        found.append((role, label, CGRect(origin: origin, size: size)))
                    }
                    if let kids = SelfTest.attr(el, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: kids) }
                }
                cont.resume(returning: (found, Date() >= deadline, visited))
            }
        }
        if timedOut { note("accessibility sweep hit its 8 s limit after \(visited) elements") }
        return found
    }

    /// Moves the real pointer well away from the panel, so no card is drawn in its hover state.
    func parkMouse() async {
        let sv = screenVisible()
        let p = CGPoint(x: sv.midX - (core.model.vertical ? 300 : 0), y: 260)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(250_000); cont.resume()
            }
        }
        await wait(0.3)
    }

    /// The scroll view that holds the clips, and how far it is from the top (0 = at the top).
    func listOffsetFromTop() -> CGFloat? {
        guard let sv = pc.cardScrollView() else { return nil }
        let insets = sv.contentInsets
        return core.model.vertical ? sv.contentView.bounds.origin.y + insets.top : sv.contentView.bounds.origin.x + insets.left
    }

    /// Settings: its scroll view, if it can scroll.
    func settingsScrollView() -> NSScrollView? {
        guard let w = NSApp.windows.first(where: { $0.title == "Copybook Settings" && $0.isVisible }) else { return nil }
        var queue: [NSView] = w.contentView.map { [$0] } ?? []
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let sv = v as? NSScrollView, let doc = sv.documentView, doc.frame.height > sv.contentView.bounds.height + 20 { return sv }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }

    /// The action bar: summary text without "from"/kind words, labelled buttons, even spacing.
    func auditActionBar(_ label: String) async {
        let vis = pc.visibleFrame, vertical = core.model.vertical
        let primary = NSScreen.screens[0].frame.height
        let visTop = CGRect(x: vis.minX, y: primary - vis.maxY, width: vis.width, height: vis.height)
        let els = await axAll().filter { visTop.intersects($0.frame) }
        let texts = els.filter { $0.role == kAXStaticTextRole }.map { $0.label }
        let selected = core.selection().first
        if let app = selected?.sourceAppName {
            check(texts.contains(app), "\(label): summary shows the app name \"\(app)\"")
            check(texts.contains { $0.hasPrefix("· ") && ($0.contains("AM") || $0.contains("PM") || $0.contains(":")) }, "\(label): summary shows the time next to it")
        }
        check(!texts.contains { $0.hasPrefix("from ") || $0.contains(" from ") && $0.contains("·") }, "\(label): no \"from …\" wording in the summary")
        check(!texts.contains { ["Text", "Image", "Colour", "Color", "Link", "File"].contains($0) && selected != nil && $0 == selected!.kind.label && false }, "\(label): summary has no kind word")
        let names = ["Paste", "Copy", "Preview"]
        let btns = names.compactMap { n in els.first { $0.role == kAXButtonRole && $0.label == n } }
        check(btns.count == 3, "\(label): Paste, Copy and Preview buttons are present")
        guard btns.count == 3 else { return }
        for b in btns { check(b.frame.width > 60, "\(label): \(b.label) button shows its word (\(Int(b.frame.width)) pt wide)") }
        let widths = btns.map { Int($0.frame.width.rounded()) }
        if vertical {
            check(Set(widths).count == 1 || (widths.max()! - widths.min()!) <= 1, "\(label): buttons share the width equally \(widths)")
            check(abs((btns[0].frame.minX - visTop.minX) - PanelStyle.verticalInset) <= 1.5, "\(label): first button \(Int(btns[0].frame.minX - visTop.minX)) pt from the left (want \(Int(PanelStyle.verticalInset)))")
            check(abs((visTop.maxX - btns[2].frame.maxX) - PanelStyle.verticalInset) <= 1.5, "\(label): last button \(Int(visTop.maxX - btns[2].frame.maxX)) pt from the right")
            let gaps = [btns[1].frame.minX - btns[0].frame.maxX, btns[2].frame.minX - btns[1].frame.maxX].map { Int($0.rounded()) }
            check(gaps.allSatisfy { $0 == 8 }, "\(label): 8 pt between buttons \(gaps)")
            check(btns.allSatisfy { abs($0.frame.height - 32) < 1.5 }, "\(label): buttons are 32 pt tall")
        }
        // The bar's content stays inside the bar.
        let barTop = visTop.maxY - PanelStyle.actionBarHeight(vertical: vertical)
        check(btns.allSatisfy { $0.frame.minY >= barTop - 1 && $0.frame.maxY <= visTop.maxY + 1 }, "\(label): buttons sit inside the action bar")
    }

    /// A real mouse click at a top-left-origin screen point, posted from a background thread.
    func realClick(_ p: CGPoint) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                func post(_ t: CGEventType) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
                post(.mouseMoved); usleep(150_000)
                post(.leftMouseDown); usleep(90_000)
                post(.leftMouseUp)
                cont.resume()
            }
        }
    }

    /// Card views in screen coordinates (bottom-left origin), top to bottom then left to right.
    func cards() -> [(item: ClipItem, frame: NSRect)] {
        var out: [(ClipItem, NSRect)] = []
        func walk(_ v: NSView) {
            if let c = v as? CardInteractionView, let item = c.item {
                out.append((item, pc.panel.convertToScreen(c.convert(c.bounds, to: nil))))
            }
            v.subviews.forEach(walk)
        }
        if let cv = pc.panel.contentView { walk(cv) }
        return out.sorted { $0.1.maxY != $1.1.maxY ? $0.1.maxY > $1.1.maxY : $0.1.minX < $1.1.minX }
    }

    func screenVisible() -> NSRect { (pc.panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    // MARK: Audits

    func audit(_ label: String, ax: Bool = true) async {
        await parkMouse()
        let vis = pc.visibleFrame
        let sv = screenVisible()
        let cs = cards()
        check(!cs.isEmpty, "\(label): cards are on screen (\(cs.count))")
        check(sv.insetBy(dx: -1, dy: -1).contains(vis), "\(label): panel is fully on screen \(NSStringFromRect(vis))")
        let vertical = core.model.vertical
        let topBar = vis.maxY - 60 - PanelStyle.topInset, actionBar = vis.minY + PanelStyle.actionBarHeight(vertical: vertical)
        if vertical {
            let inset = PanelStyle.verticalInset
            let lefts = Set(cs.map { Int($0.frame.minX.rounded()) }), rights = Set(cs.map { Int($0.frame.maxX.rounded()) })
            check(lefts.count == 1 && rights.count == 1, "\(label): cards share left and right edges (L \(lefts), R \(rights))")
            if let f = cs.first?.frame {
                check(abs((f.minX - vis.minX) - (vis.maxX - f.maxX)) <= 1.5, "\(label): cards centred, margins \(Int(f.minX - vis.minX)) / \(Int(vis.maxX - f.maxX)) (want \(Int(inset)))")
                check(abs((f.minX - vis.minX) - inset) <= 1.5, "\(label): side margin is \(Int(inset))")
            }
            for c in cs {
                let want = PanelStyle.verticalHeight(for: c.item.kind)
                if abs(c.frame.height - want) > 1.5 { check(false, "\(label): \(c.item.kind) card height \(c.frame.height) (want \(want))") }
            }
            // Vertical gaps between consecutive cards: 14, or more where a day label sits between.
            var gaps: [Int] = []
            for (a, b) in zip(cs, cs.dropFirst()) { gaps.append(Int((a.frame.minY - b.frame.maxY).rounded())) }
            let odd = gaps.filter { ![Int(PanelStyle.cardSpacing), Int(PanelStyle.cardSpacing + 16 + PanelStyle.dayLabelGap + PanelStyle.groupTopPadding)].contains($0) }
            check(odd.isEmpty, "\(label): gaps between cards \(Set(gaps).sorted()) (odd: \(odd))")
            if let first = cs.first?.frame, (pc.cardScrollView()?.contentView.bounds.origin.y ?? 0) <= 1 {
                check(first.maxY <= topBar + 1, "\(label): first card clears the search bar (\(Int(topBar - first.maxY)) pt below it)")
            }
        } else {
            let tops = Set(cs.map { Int($0.frame.maxY.rounded()) }), bottoms = Set(cs.map { Int($0.frame.minY.rounded()) })
            check(tops.count == 1 && bottoms.count == 1, "\(label): cards share top and bottom (\(tops), \(bottoms))")
            var gaps: [Int] = []
            for (a, b) in zip(cs, cs.dropFirst()) { gaps.append(Int((b.frame.minX - a.frame.maxX).rounded())) }
            let odd = gaps.filter { ![14, 28].contains($0) }
            check(odd.isEmpty, "\(label): gaps between cards \(Set(gaps).sorted()) (odd: \(odd))")
            if let f = cs.first?.frame { check(abs((f.minX - vis.minX) - 20) <= 1.5, "\(label): first card is 20 pt from the left edge") }
        }
        // Buttons: all inside the panel, none overlapping, none too close.
        // (Not after a switch to dark appearance: SwiftUI's in-process accessibility query deadlocks there.)
        guard ax else { return }
        let primary = NSScreen.screens[0].frame.height
        let visTop = CGRect(x: vis.minX, y: primary - vis.maxY, width: vis.width, height: vis.height)
        let btns = await axButtons().filter { $0.1.width > 0 && visTop.intersects($0.1) && !$0.0.isEmpty }
        let outside = btns.filter { !visTop.insetBy(dx: -1, dy: -1).contains($0.1) }
        check(outside.isEmpty, "\(label): all \(btns.count) buttons inside the panel (outside: \(outside.map { $0.0 }))")
        var overlaps: [String] = [], tight: [String] = []
        for i in 0..<btns.count { for j in (i + 1)..<btns.count {
            let a = btns[i], b = btns[j]
            if a.1.intersection(b.1).width > 1 && a.1.intersection(b.1).height > 1 && a.0 != b.0 { overlaps.append("\(a.0) × \(b.0)") }
            else if a.0 != b.0, a.1.insetBy(dx: -5, dy: -5).intersects(b.1), !a.1.intersects(b.1) { tight.append("\(a.0) | \(b.0)") }
        } }
        check(overlaps.isEmpty, "\(label): no overlapping buttons \(overlaps)")
        check(tight.isEmpty, "\(label): buttons at least 5 pt apart \(tight)")
        // Top bar content stays inside the top bar's side padding.
        if let search = btns.first(where: { $0.0 == "Search" }) {
            check(search.1.minX - visTop.minX >= 12, "\(label): search icon sits \(Int(search.1.minX - visTop.minX)) pt from the left edge")
        }
        if let more = btns.first(where: { $0.0 == "More" }) {
            check(visTop.maxX - more.1.maxX >= 12, "\(label): ••• button sits \(Int(visTop.maxX - more.1.maxX)) pt from the right edge")
        }
    }

    // MARK: Script

    func finish() {
        try? log.joined(separator: "\n").write(toFile: dir + "/layouttest.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func run() async {
        PanelController.useSavedPlacement = false
        let original = NSApp.appearance
        core.prefs.verticalLayout = false
        await wait(0.3)

        // ---- Horizontal
        pc.show(); await wait(1.5)
        check(!core.model.vertical, "starts horizontal")
        await auditActionBar("horizontal")
        capture("1-horizontal-light"); await audit("horizontal light")

        // ---- Switch to vertical with the button's own action
        note("toggling to vertical")
        core.toggleLayout(); await wait(1.2)
        check(core.model.vertical && core.prefs.verticalLayout, "toggle switches to vertical")
        check(pc.panel.isVisible && pc.panel.alphaValue > 0.99, "panel visible after switching (alpha \(pc.panel.alphaValue))")
        let vis = pc.visibleFrame, sv = screenVisible()
        check(abs(vis.width - PanelController.verticalWidth) < 1.5, "vertical width \(Int(vis.width)) (want \(Int(PanelController.verticalWidth)))")
        check(abs(vis.maxX - (sv.maxX - 10)) < 1.5, "docked to the right edge (gap \(Int(sv.maxX - vis.maxX)) pt)")
        check(abs(vis.height - (sv.height - 20)) < 1.5, "full height (\(Int(vis.height)) of \(Int(sv.height)))")
        check(core.model.cardSize.width == (vis.width - PanelStyle.verticalInset * 2).rounded(), "card width fills the panel (\(Int(core.model.cardSize.width)))")
        capture("3-vertical-light"); await audit("vertical light")
        await auditActionBar("vertical")

        // ---- Keyboard: the cursor card stays visible while moving down the list
        for _ in 0..<7 { core.moveCursor(1, extend: false, toEnd: false); await wait(0.25) }
        await wait(0.4)
        if let cur = cards().first(where: { $0.item.id == core.model.cursorID }) {
            let v = pc.visibleFrame
            // Clear of the soft fades: 18 pt above the action bar, 12 pt below the search bar.
            check(cur.frame.minY >= v.minY + PanelStyle.actionBarHeight(vertical: true) + 18 - 2 && cur.frame.maxY <= v.maxY - 60 - PanelStyle.topInset - 12 + 2,
                  "cursor card is scrolled into view (y \(Int(cur.frame.minY))…\(Int(cur.frame.maxY)))")
        } else { check(false, "cursor card is instantiated after moving down") }
        capture("5-vertical-scrolled")
        for _ in 0..<7 { core.moveCursor(-1, extend: false, toEnd: false); await wait(0.15) }
        await wait(1.0)   // let the scroll-to-top animation finish before testing the wheel

        // ---- Mouse wheel scrolls the vertical list smoothly
        if let sv = pc.cardScrollView(), let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cg) {
            let y0 = sv.contentView.bounds.origin.y
            if let doc = sv.documentView {
                note("scroll view: doc \(NSStringFromRect(doc.frame)) flipped \(doc.isFlipped) · clip \(NSStringFromRect(sv.contentView.bounds)) · insets \(sv.contentInsets) · wheel dy \(wheel.scrollingDeltaY) precise \(wheel.hasPreciseScrollingDeltas)")
            }
            let consumed = pc.smoothWheel(wheel) == nil
            await wait(1.5)
            let y1 = sv.contentView.bounds.origin.y
            note("synthetic wheel (informational only): consumed \(consumed), \(Int(y0)) → \(Int(y1))")
            if let up = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0), let upEvent = NSEvent(cgEvent: up) {
                _ = pc.smoothWheel(upEvent); await wait(1.5)
                note("synthetic wheel back up (informational only): \(Int(sv.contentView.bounds.origin.y))")
            }
        } else { check(false, "vertical scroll view found for the wheel test") }

        // ---- Resize limits
        let lim = pc.limits(on: pc.panel.screen)
        var f = pc.panel.frame
        f.size.width = lim.min.width + m * 2
        f.origin.x = sv.maxX - 10 - lim.min.width - m
        pc.panel.setFrame(f, display: true); await wait(0.8)
        check(abs(core.model.cardSize.width - (lim.min.width - 32)) < 1.5, "narrowest width: cards are \(Int(core.model.cardSize.width)) pt wide")
        capture("6-vertical-narrow"); await audit("vertical narrowest")
        f.size.width = lim.max.width + m * 2
        f.origin.x = sv.maxX - 10 - lim.max.width - m
        pc.panel.setFrame(f, display: true); await wait(0.8)
        capture("7-vertical-wide"); await audit("vertical widest")
        pc.resetPlacement(); await wait(0.8)

        // ---- Stack and preview beside the tall panel
        core.stack.add(Array(core.visibleItems().prefix(3)))
        core.stack.reposition(); await wait(0.8)
        if let stack = core.stack.visibleFrame {
            let panelVis = pc.visibleFrame
            check(!stack.intersects(panelVis), "stack clear of the panel (stack \(NSStringFromRect(stack)))")
            check(sv.insetBy(dx: -1, dy: -1).contains(stack), "stack fully on screen")
        } else { check(false, "stack window is open") }
        core.model.select(core.visibleItems().first?.id)
        core.togglePreview(); await wait(0.8)
        if core.preview.isVisible, let pv = NSApp.windows.first(where: { $0.isVisible && $0 is KeyPanel && $0 !== pc.panel && $0.frame != core.stack.visibleFrame }) {
            check(!pv.frame.intersects(pc.visibleFrame), "preview clear of the panel \(NSStringFromRect(pv.frame))")
            if let stack = core.stack.visibleFrame { check(!pv.frame.intersects(stack), "preview clear of the stack") }
            check(sv.insetBy(dx: -1, dy: -1).contains(pv.frame), "preview fully on screen")
        } else { check(false, "preview window opened") }
        core.preview.hide(); core.stack.toggle(); await wait(0.4)
        pc.panel.makeKey()

        // ---- Reopening starts from the top (vertical)
        for _ in 0..<8 { core.moveCursor(1, extend: false, toEnd: false); await wait(0.2) }
        await wait(0.6)
        let scrolledV = listOffsetFromTop() ?? 0
        check(scrolledV > 100, "vertical list is scrolled down before closing (\(Int(scrolledV)) pt)")
        pc.hide(animated: false); await wait(0.5); pc.show(); await wait(1.4)
        check((listOffsetFromTop() ?? 999) <= 1, "vertical list starts from the top when reopened (\(Int(listOffsetFromTop() ?? -1)) pt)")
        check(cards().first.map { $0.item.id == core.model.cursorID } ?? false, "the first clip is the selected one")

        // ---- Back to horizontal
        core.toggleLayout(); await wait(1.2)
        check(!core.model.vertical, "toggle switches back to horizontal")
        await audit("horizontal again")
        await auditActionBar("horizontal again")

        // ---- Reopening starts from the top (horizontal)
        for _ in 0..<9 { core.moveCursor(1, extend: false, toEnd: false); await wait(0.2) }
        await wait(0.6)
        let scrolledH = listOffsetFromTop() ?? 0
        check(scrolledH > 100, "horizontal strip is scrolled along before closing (\(Int(scrolledH)) pt)")
        pc.hide(animated: false); await wait(0.5); pc.show(); await wait(1.4)
        check((listOffsetFromTop() ?? 999) <= 1, "horizontal strip starts from the start when reopened (\(Int(listOffsetFromTop() ?? -1)) pt)")

        // ---- The panel's layout button, clicked with the real mouse (both directions)
        for round in 0..<2 {
            let was = core.model.vertical
            let btn = await axButtons().first { $0.0.hasPrefix("Switch to the") }
            check(btn != nil, "layout button is in the accessibility tree (\(btn?.0 ?? "missing"))")
            guard let btn else { break }
            await realClick(CGPoint(x: btn.1.midX, y: btn.1.midY))
            await wait(1.3)
            check(core.model.vertical != was, "real click \(round + 1) on the layout button switches to \(was ? "horizontal" : "vertical")")
            check(pc.panel.isVisible, "panel stays open after the click")
        }

        // ---- The Settings toggle, clicked with the real mouse
        let wasVertical = core.model.vertical
        core.openSettings(); await wait(1.2)
        let sw = await axAll().first { $0.label == "Vertical layout" }
        check(sw != nil, "Settings has a switch labelled Vertical layout (\(sw?.role ?? "missing"))")
        if let sw {
            await realClick(CGPoint(x: sw.frame.midX, y: sw.frame.midY))
            await wait(1.4)
            check(core.prefs.verticalLayout != wasVertical, "clicking the Settings switch changes the layout setting")
            check(core.model.vertical == core.prefs.verticalLayout, "the panel follows the setting")
            await realClick(CGPoint(x: sw.frame.midX, y: sw.frame.midY))
            await wait(1.4)
            check(core.prefs.verticalLayout == wasVertical, "clicking it again switches back")
        }
        NSApp.windows.filter { !($0 is KeyPanel) && $0.isVisible && $0.title.isEmpty == false || $0.styleMask.contains(.titled) }.forEach { $0.orderOut(nil) }
        pc.show(); await wait(1.5)

        // ---- Settings pages always start from the top
        core.openSettings(); await wait(1.2)
        if let sv = settingsScrollView() {
            let tabs = await axAll().filter { $0.role == kAXButtonRole || $0.role == kAXStaticTextRole }
            func top(_ sv: NSScrollView) -> CGFloat { sv.contentView.bounds.origin.y + sv.contentInsets.top }
            func scrollSettingsDown() {
                guard let sv = settingsScrollView(), let doc = sv.documentView else { return }
                sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - sv.contentView.bounds.height)))
                sv.reflectScrolledClipView(sv.contentView)
            }
            scrollSettingsDown(); await wait(0.4)
            check((settingsScrollView().map(top) ?? 0) > 20, "General page can be scrolled down (\(Int(settingsScrollView().map(top) ?? 0)) pt)")
            for page in ["Shortcuts", "Privacy", "General"] {
                guard let tab = tabs.first(where: { $0.label == page }) else { check(false, "settings tab \(page) found"); continue }
                await realClick(CGPoint(x: tab.frame.midX, y: tab.frame.midY)); await wait(0.9)
                let t = settingsScrollView().map(top) ?? 0
                check(t <= 1, "switching to \(page) starts from the top (\(Int(t)) pt)")
                scrollSettingsDown(); await wait(0.3)
            }
            // Close and reopen: back to the top as well.
            NSApp.windows.first(where: { $0.title == "Copybook Settings" })?.orderOut(nil); await wait(0.4)
            core.openSettings(); await wait(1.2)
            check((settingsScrollView().map(top) ?? 0) <= 1, "reopening Settings starts from the top (\(Int(settingsScrollView().map(top) ?? -1)) pt)")
        } else { check(false, "the Settings page is scrollable for this test") }
        NSApp.windows.filter { $0.title == "Copybook Settings" }.forEach { $0.orderOut(nil) }
        pc.show(); await wait(1.5)

        // ---- Opening and closing over and over, in both layouts
        for layoutVertical in [false, true] {
            core.prefs.verticalLayout = layoutVertical; await wait(1.4)
            var rng2 = SystemRandomNumberGenerator()
            for _ in 0..<12 {
                pc.toggle(); await wait(Double.random(in: 0.03...0.45, using: &rng2))
            }
            await wait(0.8)   // let a closing animation finish before deciding whether to reopen
            if !pc.panel.isVisible { pc.show() }
            await wait(1.5)
            let want = pc.targetFrame()
            check(pc.panel.isVisible && pc.panel.alphaValue > 0.99 && core.model.revealed, "\(layoutVertical ? "vertical" : "horizontal"): visible, opaque and revealed after 12 open/close taps")
            check(abs(pc.panel.frame.minX - want.minX) < 1.5 && abs(pc.panel.frame.minY - want.minY) < 1.5 && abs(pc.panel.frame.width - want.width) < 1.5,
                  "\(layoutVertical ? "vertical" : "horizontal"): back at its place \(NSStringFromRect(pc.panel.frame))")
        }

        // ---- Rapid toggling must settle in a consistent state
        if !pc.panel.isVisible { pc.show(); await wait(1.5) }
        var rng = SystemRandomNumberGenerator()
        let speeds: [ClosedRange<Double>] = [0.02...0.12, 0.05...0.25, 0.08...0.15, 0.02...0.3, 0.1...0.13, 0.03...0.07]
        for (round, range) in speeds.enumerated() {
            for _ in 0..<14 { core.toggleLayout(); await wait(Double.random(in: range, using: &rng)) }
            await wait(1.7)
            check(core.model.vertical == core.prefs.verticalLayout, "rapid round \(round + 1): after 14 flips the panel matches the setting (\(core.model.vertical ? "vertical" : "horizontal"))")
            check(pc.panel.isVisible && pc.panel.alphaValue > 0.99 && core.model.revealed, "rapid round \(round + 1): visible, opaque and revealed")
            let want = pc.targetFrame()
            check(abs(pc.panel.frame.minX - want.minX) < 1.5 && abs(pc.panel.frame.width - want.width) < 1.5 && abs(pc.panel.frame.height - want.height) < 1.5,
                  "rapid round \(round + 1): frame matches the layout's placement \(NSStringFromRect(pc.panel.frame)) vs \(NSStringFromRect(want))")
        }
        await audit("after rapid toggles")

        // ---- Hiding in the middle of a switch must not bring the panel back
        core.toggleLayout(); await wait(0.03); pc.hide(); await wait(1.0)
        check(!pc.panel.isVisible, "panel stays hidden when closed during a switch")
        pc.show(); await wait(1.5)
        check(core.model.vertical == core.prefs.verticalLayout && pc.panel.isVisible, "reopens in the chosen layout (\(core.model.vertical ? "vertical" : "horizontal"))")
        await audit("reopened")

        // ---- Dark appearance: screenshots and card geometry (no accessibility sweep from here on)
        core.prefs.verticalLayout = false; await wait(1.2)
        NSApp.appearance = NSAppearance(named: .darkAqua); await wait(1.0)
        capture("2-horizontal-dark"); await audit("horizontal dark", ax: false)
        core.toggleLayout(); await wait(1.3)
        capture("4-vertical-dark"); await audit("vertical dark", ax: false)
        for _ in 0..<5 { core.moveCursor(1, extend: false, toEnd: false); await wait(0.25) }
        await wait(0.5); capture("8-vertical-dark-scrolled")

        // ---- Settings window shows the toggle
        core.openSettings(); await wait(1.0)
        note("settings opened")

        core.prefs.verticalLayout = false
        NSApp.appearance = original
        log.append("")
        log.append("RESULT: \(failures == 0 ? "all checks passed" : "\(failures) FAILED")")
        try? log.joined(separator: "\n").write(toFile: dir + "/layouttest.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
