import AppKit
import SwiftUI

/// Debug aid (COPYBOOK_PINTEST=<size|pin>, COPYBOOK_PINTEST_DIR=<dir>, with COPYBOOK_TEST_DEFAULTS=1):
/// "size" drags the panel's edges to extremes with the real mouse in both layouts and checks the size
/// limits, the shape rule and that cards never outgrow the panel. "pin" checks the pin button.
extension LayoutTest {
    func realDrag(from a: CGPoint, to b: CGPoint) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
                post(.mouseMoved, a); usleep(150_000)
                post(.leftMouseDown, a); usleep(200_000)
                for k in 1...40 { let t = CGFloat(k) / 40; post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); usleep(15_000) }
                usleep(250_000); post(.leftMouseUp, b)
                cont.resume()
            }
        }
    }

    /// Top-left-origin screen point for a bottom-left-origin one.
    func cg(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: NSScreen.screens[0].frame.height - p.y) }

    /// Closes the "keep this size?" prompt if it is up.
    func dismissPrompt() async {
        await wait(0.6)   // the prompt appears a moment after the mouse is released
        if core.model.placementPrompt { pc.keepPlacement(always: false) }
        await wait(0.9)
    }

    func finishPinTest(_ name: String) {
        try? log.joined(separator: "\n").appending("\n\nRESULT: \(failures == 0 ? "all checks passed" : "\(failures) FAILED")\n")
            .write(toFile: dir + "/\(name).log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func runPinStage(_ stage: String) async {
        PanelController.useSavedPlacement = false
        core.prefs.setupCompleted = true
        await wait(1.0)
        switch stage {
        case "size": await sizeStage()
        case "pin": await pinStage()
        case "level": await levelStage()
        case "style": await styleStage()
        default: check(false, "unknown stage \(stage)")
        }
        finishPinTest("pintest")
    }

    // MARK: Sizes

    private func visDims() -> (w: CGFloat, h: CGFloat) { (pc.visibleFrame.width, pc.visibleFrame.height) }

    private func checkShape(_ label: String) {
        let (w, h) = visDims(), l = pc.limits(on: pc.panel.screen)
        let vertical = core.model.vertical
        check(w >= l.min.width - 1 && h >= l.min.height - 1, "\(label): at least the minimum size (\(Int(w))×\(Int(h)), min \(Int(l.min.width))×\(Int(l.min.height)))")
        check(w <= l.max.width + 1 && h <= l.max.height + 1, "\(label): at most the maximum size (max \(Int(l.max.width))×\(Int(l.max.height)))")
        check(vertical ? h > w : w > h, "\(label): \(vertical ? "taller than wide" : "wider than tall") (\(Int(w))×\(Int(h)))")
        check(h / w >= l.aspect.lowerBound - 0.01 && h / w <= l.aspect.upperBound + 0.01, "\(label): shape within \(String(format: "%.2f", l.aspect.lowerBound))…\(String(format: "%.2f", l.aspect.upperBound)) (is \(String(format: "%.2f", h / w)))")
        if !vertical {
            check(core.model.cardSize.height <= PanelStyle.maxCardHeight + 0.5, "\(label): cards at most \(Int(PanelStyle.maxCardHeight)) pt tall (\(Int(core.model.cardSize.height)))")
            check(core.model.cardSize.width <= w - CardStrip.leading * 2 + 0.5, "\(label): a card is never wider than the panel (card \(Int(core.model.cardSize.width)), panel \(Int(w)))")
        }
        if let first = cards().first {
            let v = pc.visibleFrame
            check(first.frame.minX >= v.minX - 0.5 && first.frame.maxX <= v.maxX + 0.5 && first.frame.minY >= v.minY - 0.5 && first.frame.maxY <= v.maxY + 0.5,
                  "\(label): the first card sits fully inside the panel")
        }
    }

    private func sizeStage() async {
        pc.show(); await wait(1.5)
        await parkMouse()
        check(!core.model.vertical, "starts horizontal")
        checkShape("default horizontal")
        capture("size-1-default")

        // Pull the top edge up as far as the screen allows.
        var v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.midX - 300, y: v.maxY + 4)), to: cg(NSPoint(x: v.midX - 300, y: v.maxY + 700)))
        await dismissPrompt(); await wait(0.5)
        checkShape("top edge dragged far up")
        capture("size-2-tall")

        // Squeeze the width as far as it will go.
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.maxX + 4, y: v.midY)), to: cg(NSPoint(x: v.maxX - 1800, y: v.midY)))
        await dismissPrompt(); await wait(0.5)
        checkShape("right edge squeezed")
        capture("size-3-narrow")

        // A corner dragged in both directions at once.
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.minX - 3, y: v.maxY + 3)), to: cg(NSPoint(x: v.minX + 900, y: v.maxY + 700)))
        await dismissPrompt(); await wait(0.5)
        checkShape("corner dragged hard")

        // A saved size from an older version (huge and tall) is brought back within the limits.
        core.prefs.panelFrame = NSRect(x: 100, y: 60, width: 900, height: 1300)
        PanelController.useSavedPlacement = true
        pc.hide(animated: false); await wait(0.5); pc.show(); await wait(1.5)
        PanelController.useSavedPlacement = false
        checkShape("a huge saved size")
        core.prefs.panelFrame = nil

        // The prompt: a picture to look at (the grey rim is gone), and cards stay inside the panel.
        pc.panel.setFrame(pc.defaultFrame(on: pc.panel.screen ?? NSScreen.main!), display: true); await wait(0.6)
        pc.beginPlacementChange(); pc.endPlacementChange(); await wait(1.0)
        capture("size-4-prompt")
        await dismissPrompt()

        // ---- Vertical
        core.toggleLayout(); await wait(1.6)
        check(core.model.vertical, "switched to vertical")
        await parkMouse()
        checkShape("default vertical")
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.minX - 3, y: v.midY)), to: cg(NSPoint(x: v.minX - 900, y: v.midY)))
        await dismissPrompt(); await wait(0.5)
        checkShape("left edge dragged far out")
        capture("size-5-vertical-wide")
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.midX - 40, y: v.minY - 3)), to: cg(NSPoint(x: v.midX - 40, y: v.minY + 900)))
        await dismissPrompt(); await wait(0.5)
        checkShape("bottom edge pulled far up")
        capture("size-6-vertical-short")
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.maxX + 3, y: v.midY)), to: cg(NSPoint(x: v.maxX - 900, y: v.midY)))
        await dismissPrompt(); await wait(0.5)
        checkShape("right edge squeezed")

        // ---- At the smallest sizes every button still fits, with the stack button showing too.
        core.stack.add(Array(core.visibleItems().prefix(2))); await wait(0.6)
        await audit("vertical smallest")
        core.stack.toggle(); await wait(0.4)
        core.toggleLayout(); await wait(1.6)
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.maxX + 3, y: v.midY)), to: cg(NSPoint(x: v.maxX - 1800, y: v.midY)))
        await dismissPrompt(); await wait(0.6)
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.midX - 300, y: v.maxY + 4)), to: cg(NSPoint(x: v.midX - 300, y: v.maxY - 600)))
        await dismissPrompt(); await wait(0.6)
        checkShape("horizontal smallest")
        let primary = NSScreen.screens[0].frame.height
        let vis = pc.visibleFrame
        let top = CGRect(x: vis.minX, y: primary - vis.maxY, width: vis.width, height: vis.height)
        let btns = await axButtons().filter { $0.1.width > 0 && top.intersects($0.1) && !$0.0.isEmpty }
        let names = btns.map { $0.0 }
        for n in ["Search", "Pick a colour from the screen (⌃⇧⌘C)", "More", "Pin in place"] {
            check(names.contains { $0 == n || $0.hasPrefix(n.prefix(10)) }, "smallest horizontal: \"\(n)\" button is there")
        }
        check(btns.allSatisfy { top.insetBy(dx: -1, dy: -1).contains($0.1) }, "smallest horizontal: every button is inside the panel")
        var overlaps: [String] = []
        for i in 0..<btns.count { for j in (i + 1)..<btns.count where btns[i].0 != btns[j].0 {
            let x = btns[i].1.intersection(btns[j].1); if x.width > 1 && x.height > 1 { overlaps.append("\(btns[i].0) × \(btns[j].0)") }
        } }
        check(overlaps.isEmpty, "smallest horizontal: no overlapping buttons \(overlaps)")
        capture("size-7-horizontal-smallest")
    }

    // MARK: Pin

    private func esc() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: pc.panel.windowNumber, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    private func pinStage() async {
        Paster.dryRun = true
        pc.show(); await wait(1.5); await parkMouse()
        check(!core.model.pinned, "starts unpinned")
        guard let pin = await axButtons().first(where: { $0.0 == "Pin in place" }) else { check(false, "the Pin button is in the panel"); return }
        check(pin.1.width > 20, "the Pin button is in the panel")
        await realClick(CGPoint(x: pin.1.midX, y: pin.1.midY)); await wait(0.9)
        check(core.model.pinned, "clicking Pin pins the panel")
        check(await axButtons().contains { $0.0 == "Unpin" }, "the button now says Unpin")
        let frame = pc.panel.frame
        capture("pin-1-pinned")

        // ---- Locked: no moving or resizing
        var v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.midX - 300, y: v.maxY - 10)), to: cg(NSPoint(x: v.midX - 100, y: v.maxY - 200)))
        check(pc.panel.frame == frame, "dragging the top strip does nothing while pinned")
        await realDrag(from: cg(NSPoint(x: v.midX, y: v.maxY - 7)), to: cg(NSPoint(x: v.midX + 200, y: v.maxY - 100)))
        check(pc.panel.frame == frame, "dragging the pin in the strip does nothing")
        await realDrag(from: cg(NSPoint(x: v.maxX + 4, y: v.midY)), to: cg(NSPoint(x: v.maxX - 300, y: v.midY)))
        check(pc.panel.frame == frame, "dragging the edge does nothing while pinned")
        await realDrag(from: cg(NSPoint(x: v.midX - 300, y: v.maxY + 4)), to: cg(NSPoint(x: v.midX - 300, y: v.maxY + 200)))
        check(pc.panel.frame == frame && !core.model.placementPrompt, "dragging the top border does nothing, and no prompt appears")

        // ---- Stays when you click away, press Esc or use the shortcut
        pc.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)); await wait(0.8)
        check(pc.panel.isVisible, "losing focus doesn't close a pinned panel")
        let before = NSWorkspace.shared.frontmostApplication
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(); await wait(1.2)
        check(pc.panel.isVisible && pc.panel.frame == frame, "activating another app (Finder) leaves it exactly where it was")
        before?.activate(); await wait(0.6)
        _ = pc.handle(esc()); await wait(0.6)
        check(pc.panel.isVisible, "Esc doesn't close a pinned panel")
        pc.toggle(); await wait(0.8)
        check(pc.panel.isVisible && pc.panel.frame == frame, "the open-Copybook shortcut doesn't close it either")
        pc.show(); await wait(0.6)
        check(pc.panel.frame == frame, "opening it again doesn't move it")

        // ---- Pasting keeps it open
        if let first = core.visibleItems().first {
            core.paste([first]); await wait(0.9)
            check(pc.panel.isVisible && pc.panel.frame == frame, "pasting a clip leaves a pinned panel open")
        }

        // ---- Steps aside for the colour picker and comes back to the same place
        pc.hide(animated: false, force: true); await wait(0.6)
        check(!pc.panel.isVisible, "a forced hide (the colour picker) does hide it")
        pc.show(); await wait(1.5)
        check(core.model.pinned && abs(pc.panel.frame.minX - frame.minX) < 1.5 && abs(pc.panel.frame.minY - frame.minY) < 1.5 && abs(pc.panel.frame.width - frame.width) < 1.5 && abs(pc.panel.frame.height - frame.height) < 1.5,
              "it comes back to exactly the same frame \(NSStringFromRect(pc.panel.frame))")

        // ---- Switching layout keeps the pin
        core.toggleLayout(); await wait(1.7)
        check(core.model.pinned && pc.panel.isVisible && core.model.vertical, "switching to vertical keeps it pinned and open")
        pc.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)); await wait(0.6)
        check(pc.panel.isVisible, "…and it still ignores clicking away")
        core.toggleLayout(); await wait(1.7)
        check(core.model.pinned && pc.panel.isVisible && !core.model.vertical, "switching back keeps it pinned too")
        let frame2 = pc.panel.frame

        // ---- Unpin
        guard let unpin = await axButtons().first(where: { $0.0 == "Unpin" }) else { check(false, "the Unpin button is in the panel"); return }
        await realClick(CGPoint(x: unpin.1.midX, y: unpin.1.midY)); await wait(0.9)
        check(!core.model.pinned, "clicking Unpin unpins it")
        check(await axButtons().contains { $0.0 == "Pin in place" }, "the button says Pin again")
        v = pc.visibleFrame
        await realDrag(from: cg(NSPoint(x: v.minX + 160, y: v.maxY - 10)), to: cg(NSPoint(x: v.minX + 260, y: v.maxY - 10)))
        check(pc.panel.frame != frame2, "once unpinned the strip moves it again (\(NSStringFromRect(frame2)) → \(NSStringFromRect(pc.panel.frame)))")
        await dismissPrompt()
        pc.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)); await wait(0.8)
        check(!pc.panel.isVisible, "and clicking away closes it as usual")
        Paster.dryRun = false
    }

    // MARK: Window levels

    /// Front-to-back order of the windows currently on screen, as the window server composites them.
    private func stackingOrder() -> [Int] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    private func levelStage() async {
        pc.show(); await wait(1.6)
        core.stack.add(Array(core.visibleItems().prefix(2))); await wait(0.8)   // creates the Stack window
        let panelNumber = pc.panel.windowNumber
        check(pc.panel.level == WindowLevels.overlay, "the panel is at the shared overlay level (\(pc.panel.level.rawValue))")
        check(core.preview.windowLevel == WindowLevels.overlay, "the preview window is at the shared level")
        check(core.stack.windowLevel == WindowLevels.overlay, "the Stack window is at the shared level")

        // Stand-in windows, all over the middle of the panel: app-like levels and the system's own.
        let vis = pc.visibleFrame
        let spots: [(String, Int, NSColor)] = [
            ("normal app window", 0, .systemGray), ("an app's floating window", 3, .systemBlue), ("a modal panel", 8, .systemGreen),
            ("Stage Manager", 16, .systemPurple), ("the Dock", 20, .systemOrange), ("a notification (Notification Centre)", 23, .systemRed),
            ("the menu bar", 24, .systemPink),
        ]
        var windows: [(String, Int, NSWindow)] = []
        for (i, spot) in spots.enumerated() {
            let w = NSPanel(contentRect: NSRect(x: vis.midX - 200 + CGFloat(i) * 14, y: vis.midY - 60, width: 160, height: 90),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: spot.1)
            w.backgroundColor = spot.2
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            w.orderFrontRegardless()
            windows.append((spot.0, spot.1, w))
        }
        await wait(0.8)
        let order = stackingOrder()
        func pos(_ number: Int) -> Int { order.firstIndex(of: number) ?? Int.max }
        let panelPos = pos(panelNumber)
        check(panelPos != Int.max, "the panel is on screen")
        for (name, level, w) in windows {
            let p = pos(w.windowNumber)
            guard p != Int.max else { check(false, "\(name) (level \(level)) is on screen"); continue }
            if level < WindowLevels.overlay.rawValue {
                check(panelPos < p, "the panel is in front of \(name) (level \(level))")
            } else {
                check(p < panelPos, "\(name) (level \(level)) is in front of the panel")
            }
        }
        windows.forEach { $0.2.orderOut(nil) }

        // What the real system windows on this Mac are doing right now.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in info {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if ["Dock", "Notification Centre", "Notification Center", "Window Server", "Siri", "Control Centre", "SystemUIServer", "WindowManager"].contains(owner), layer >= 0 {
                note("real system window: \(owner) at level \(layer)")
            }
            if ["Dock", "Notification Centre", "Notification Center", "Siri"].contains(owner), layer > 0 {
                check(layer > WindowLevels.overlay.rawValue, "real \(owner) window (level \(layer)) is above Copybook")
            }
        }
    }
}
