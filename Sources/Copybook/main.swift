import AppKit
import SwiftUI
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            // (A test run with its own data folder may run beside the real app.)
            let separateTest = ProcessInfo.processInfo.environment["COPYBOOK_DATA_DIR"] != nil && ProcessInfo.processInfo.environment["COPYBOOK_TEST_DEFAULTS"] != nil
            if !others.isEmpty && !separateTest { NSApp.terminate(nil); return }
        }
        MainActor.assumeIsolated { AppCore.shared.start() }
        let env = ProcessInfo.processInfo.environment
        let testing = env["COPYBOOK_TEST_DEFAULTS"] != nil
        if !testing { Footprint.Manifest.recordLaunch() }
        // First-run setup resumes at the step it was on until it is finished or skipped.
        if !Prefs.shared.setupCompleted && (!testing || env["COPYBOOK_SHOW_SETUP"] != nil) {
            MainActor.assumeIsolated { AppCore.shared.showSetup() }
        }
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_SELFTEST"] {
            MainActor.assumeIsolated { SelfTest(dir: dir).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_DRAGTEST"] {
            MainActor.assumeIsolated { DragTest(dir: dir).run() }
        }
        if let stage = ProcessInfo.processInfo.environment["COPYBOOK_SETUPTEST"], let dir = ProcessInfo.processInfo.environment["COPYBOOK_SETUPTEST_DIR"] {
            Task { @MainActor in await LayoutTest(dir: dir).runSetup(stage: stage) }
        }
        if let stage = ProcessInfo.processInfo.environment["COPYBOOK_PINTEST"], let dir = ProcessInfo.processInfo.environment["COPYBOOK_PINTEST_DIR"] {
            Task { @MainActor in await LayoutTest(dir: dir).runPinStage(stage) }
        }
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_FOOTPRINTTEST"] {
            MainActor.assumeIsolated { FootprintTest.run(dir: dir) }
        }
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_LAYOUTTEST"] {
            Task { @MainActor in await LayoutTest(dir: dir).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_COMPOSITE"] {
            MainActor.assumeIsolated { CompositeTest(dir: dir).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_EDGETEST"] {
            MainActor.assumeIsolated { EdgeTest(dir: dir).run() }
        }
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_RESIZETEST"] {
            MainActor.assumeIsolated { ResizeTest(dir: dir).run() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppCore.shared.panelController.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { if !AppCore.shared.isUninstalling { AppCore.shared.store.saveNow() } }
    }
}

/// Debug aid (COPYBOOK_SELFTEST=<dir>): renders the panel to PNGs and drives the
/// click / double-click behaviour with in-process mouse events. Needs no permissions.
@MainActor
struct SelfTest {
    let dir: String

    func run() {
        let core = AppCore.shared
        Paster.dryRun = true
        for (name, paused) in [("menubar-icon", false), ("menubar-icon-paused", true)] {
            let img = MenuBarIcon.image(paused: paused)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 72, height: 72).fill()
            img.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
        PanelController.useSavedPlacement = false
        let panel = core.panelController.panel
        var log: [String] = []
        let pb = NSPasteboard.general
        let cardCenter = NSPoint(x: CardStrip.leading + CardView.size.width / 2, y: CardStrip.bottom + CardView.size.height / 2)

        // Colour picker formatting.
        let dodger = NSColor(srgbRed: 30 / 255, green: 144 / 255, blue: 1, alpha: 1)
        for (fmt, want) in [(ScreenColorPicker.Format.hex, "#1E90FF"), (.rgb, "rgb(30, 144, 255)")] {
            let got = ScreenColorPicker.string(for: dodger, format: fmt)
            log.append(got == want && ColorParser.parse(got) != nil ? "picker \(fmt): \(got)" : "FAIL: picker \(fmt) gave \(got)")
        }

        // Image drags carry a real PNG file (browsers and chat apps only accept files).
        if let img = core.store.items.first(where: { $0.kind == .image }),
           let p = Paster.dragWriters(for: img, store: core.store).first as? NSPasteboardItem {
            let file = p.string(forType: .fileURL).flatMap(URL.init(string:))
            let ok = file.map { FileManager.default.fileExists(atPath: $0.path) && NSImage(contentsOf: $0) != nil } ?? false
            log.append(ok ? "image drag file: \(file!.lastPathComponent) · types \(p.types.map(\.rawValue))" : "FAIL: image drag has no PNG file")
        }

        core.panelController.show()
        after(1.2) {
            snapshot(panel, "panel.png")
            guard let first = core.visibleItems().first else {
                log.append("FAIL: no items to test"); write(log); return
            }
            pb.clearContents()
            pb.setString("selftest-sentinel", forType: .string)
            core.monitor.ignore(changeCount: pb.changeCount)

            click(panel, at: cardCenter, count: 1)
            after(0.35) {
                snapshot(panel, "panel-copied.png")
                let copied = pb.string(forType: .string)
                log.append("single click → clipboard is first clip: \(copied == first.text) (\(String((copied ?? "nil").prefix(40))))")
                log.append("single click → panel still open: \(panel.isVisible)")
                log.append("single click → 'Copied' badge shown: \(core.model.flash?.id == first.id)")

                click(panel, at: cardCenter, count: 1)
                click(panel, at: cardCenter, count: 2)
                after(0.5) {
                    let trusted = Paster.isTrusted
                    log.append("accessibility trusted: \(trusted)")
                    if trusted {
                        log.append("double click → panel closed for paste: \(!panel.isVisible)")
                    } else {
                        log.append("double click (no access) → panel stays open with notice: \(panel.isVisible && core.model.showAccessNotice)")
                    }
                    log.append("double click → clipboard holds clip: \(pb.string(forType: .string) == first.text)")
                    snapshot(panel, "panel-notice.png")
                    buttonAudit(core: core, log: log) { log in
                        placementTest(core: core, log: log) { stackAndSettings(core: core, log: $0) }
                    }
                }
            }
        }
    }

    /// Finds every button the panel exposes to accessibility, checks each has a name, and
    /// presses the search button the way VoiceOver would.
    private func buttonAudit(core: AppCore, log: [String], then next: @escaping ([String]) -> Void) {
        var log = log
        core.panelController.show()
        log.append("reveal starts hidden on open: \(core.model.revealed == false)")
        after(1.0) {
            log.append("cards revealed after open: \(core.model.revealed)")
            axButtons { buttons in
                log.append("panel buttons: \(buttons.map { $0.0.isEmpty ? "<unnamed>" : $0.0 }.joined(separator: ", "))")
                log.append("unnamed buttons: \(buttons.filter { $0.0.isEmpty }.count)")
                if let search = buttons.first(where: { $0.0 == "Search" }) { press(search.1) }
                after(0.5) {
                    log.append("search button opens search: \(core.model.searchOpen)")
                    snapshot(core.panelController.panel, "panel-search.png")
                    core.model.searchOpen = false
                    after(0.7) {
                        let actions = ["Paste", "Copy", "Preview"]
                        log.append("action bar buttons: \(actions.filter { a in buttons.contains { $0.0 == a } }.joined(separator: ", "))")
                        core.panelController.hide(animated: false)
                        log.append("reveal reset while hidden: \(core.model.revealed == false)")
                        next(log)
                    }
                }
            }
        }
    }

    /// Resizes the panel the way the edge handles do, then checks the cards scaled, the
    /// prompt appeared over a blurred panel, and "Just for now" leaves saved settings alone.
    private func placementTest(core: AppCore, log: [String], then next: @escaping ([String]) -> Void) {
        var log = log
        let pc = core.panelController
        let savedBefore = Prefs.shared.panelFrame
        pc.show()
        after(0.8) {
            // Drag: the preview is a rounded card, and the data includes plain text for other apps.
            if let first = core.visibleItems().first {
                let img = DragImage.render(for: first, count: 1, store: core.store, appearance: pc.panel.effectiveAppearance)
                var rect = NSRect(origin: .zero, size: img.size)
                if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir + "/drag-preview.png"))
                }
                let writers = Paster.dragWriters(for: first, store: core.store)
                let types = writers.flatMap { ($0 as? NSPasteboardItem)?.types.map(\.rawValue) ?? ($0 is NSURL ? ["public.file-url"] : []) }
                log.append("drag carries: \(types.joined(separator: ", "))")
            }
            // Mouse wheel: one notch should glide the strip sideways.
            if let sv = pc.cardScrollView(),
               let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0),
               let wheel = NSEvent(cgEvent: cg) {
                let x0 = sv.contentView.bounds.origin.x
                let consumed = pc.smoothWheel(wheel) == nil
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                log.append("mouse wheel glides strip: \(consumed && sv.contentView.bounds.origin.x > x0) (\(Int(x0)) → \(Int(sv.contentView.bounds.origin.x)) pt)")
                sv.contentView.setBoundsOrigin(.zero)
            } else {
                log.append("mouse wheel glides strip: no scroll view found")
            }
            let before = core.model.cardSize
            var f = pc.panel.frame
            f.size.height = 470
            pc.beginPlacementChange()
            pc.panel.setFrame(f, display: true)
            log.append("frame right after resize: \(pc.panel.frame.height) · min \(pc.panel.minSize.height) · content fitting \(pc.panel.contentView?.fittingSize.height ?? -1)")
            pc.endPlacementChange()
            after(0.6) {
                log.append("resize grows cards: \(core.model.cardSize.height > before.height) (\(Int(before.height)) → \(Int(core.model.cardSize.height)) pt)")
                log.append("prompt shown after resize: \(core.model.placementPrompt)")
                snapshot(pc.panel, "panel-placement-prompt.png")
                // Outside the rounded corners the panel must be fully transparent, or macOS draws
                // its shadow (and catches clicks) around a square shape.
                func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
                let host = pc.panel.contentView.flatMap { allViews($0).first { String(describing: type(of: $0)).contains("FirstMouseHostingView") } }
                log.append("glass container: \(pc.panel.contentView.map { String(describing: type(of: $0)) } ?? "nil") · host found \(host != nil)")
                if let content = host, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    let w = rep.pixelsWide, h = rep.pixelsHigh, k = 3
                    let corners = [(k, k), (w - 1 - k, k), (k, h - 1 - k), (w - 1 - k, h - 1 - k)]
                    let alphas = corners.map { rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? -1 }
                    let edge = rep.colorAt(x: w / 3, y: 2)?.alphaComponent ?? -1
                    log.append(alphas.allSatisfy { $0 == 0 }
                        ? "corners stay round while resizing: true (edge alpha \(String(format: "%.3f", edge)))"
                        : "FAIL: corner pixels not transparent: \(alphas)")
                }
                pc.keepPlacement(always: false)
                after(0.4) {
                    log.append("'Just for now' keeps size while open: \(Int(pc.panel.frame.height) == 470)")
                    log.append("'Just for now' leaves saved placement alone: \(Prefs.shared.panelFrame == savedBefore)")
                    // Small panel: everything keeps its shape, compact layouts take over.
                    var narrow = pc.panel.frame
                    narrow.size = NSSize(width: 620, height: 330)
                    pc.panel.setFrame(narrow, display: true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    snapshot(pc.panel, "panel-narrow.png")
                    pc.hide(animated: false)
                    log.append("panel returns to default after closing: \(Int(pc.targetFrame().height) == Int(PanelController.height + PanelController.margin * 2))")
                    next(log)
                }
            }
        }
    }

    /// Reads this app's interface through the public Accessibility API, exactly as VoiceOver
    /// would, on a background thread so the main thread stays free to answer.
    private func axButtons(_ completion: @escaping ([(String, CGRect)]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(getpid())
            AXUIElementSetMessagingTimeout(app, 3)
            var found: [(String, CGRect)] = []
            var pending: [AXUIElement] = [app]
            var visited = 0
            while let el = pending.popLast(), visited < 8000 {
                visited += 1
                let role = SelfTest.attr(el, kAXRoleAttribute) as? String
                if role == kAXButtonRole || role == kAXMenuButtonRole || role == kAXPopUpButtonRole {
                    let label = [kAXDescriptionAttribute, kAXTitleAttribute]
                        .compactMap { SelfTest.attr(el, $0) as? String }
                        .first { !$0.isEmpty } ?? ""
                    var origin = CGPoint.zero, size = CGSize.zero
                    if let p = SelfTest.attr(el, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
                    if let z = SelfTest.attr(el, kAXSizeAttribute) { AXValueGetValue(z as! AXValue, .cgSize, &size) }
                    found.append((label, CGRect(origin: origin, size: size)))
                }
                if let kids = SelfTest.attr(el, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: kids) }
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    nonisolated static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    /// Clicks the centre of an accessibility frame (top-left screen coordinates) with a real
    /// mouse event, so hit-testing is exercised exactly as for a user's click.
    private func press(_ frame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenPoint = NSPoint(x: frame.midX, y: primaryHeight - frame.midY)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(screenPoint) }) else { return }
        click(window, at: window.convertPoint(fromScreen: screenPoint), count: 1)
    }

    private func stackAndSettings(core: AppCore, log: [String]) {
        var log = log
        core.panelController.hide(animated: false)
        core.stack.add(Array(core.visibleItems().prefix(3)))
        core.panelController.show()
        after(1.0) {
            let main = core.panelController.panel.frame
            if let stack = core.stack.visibleFrame {
                log.append("stack frame \(NSStringFromRect(stack)) · panel frame \(NSStringFromRect(main))")
                log.append("stack overlaps panel: \(stack.intersects(main))")
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.frame == stack }) { snapshot(w, "stack.png") }
            }
            let firstBefore = core.stack.items.first?.id
            axButtons { buttons in
                let stackLabels = ["Paste everything", "Flip the order", "Clear the stack", "Close Stack"]
                log.append("stack buttons found: \(stackLabels.filter { l in buttons.contains { $0.0 == l } }.joined(separator: ", "))")
                if let rev = buttons.first(where: { $0.0 == "Flip the order" }) { press(rev.1) }
                after(0.5) {
                    log.append("reverse button reorders stack: \(core.stack.items.first?.id != firstBefore)")
                    previewAndSettings(core: core, log: log, close: buttons.first(where: { $0.0 == "Close Stack" })?.1)
                }
            }
        }
    }

    private func previewAndSettings(core: AppCore, log: [String], close: CGRect?) {
        var log = log
        do {
            core.togglePreview()
            after(0.6) {
                if let stack = core.stack.visibleFrame,
                   let pv = NSApp.windows.first(where: { $0.isVisible && $0 is KeyPanel && $0 !== core.panelController.panel && $0.frame != stack }) {
                    log.append("preview overlaps stack: \(pv.frame.intersects(stack))")
                }
                if let close { press(close) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                log.append("close button closes stack: \(!core.stack.isActive)")
                core.stack.close()
                core.panelController.hide(animated: false)
                for page in SettingsPage.allCases {
                    for dark in [false, true] { renderSettings(core: core, page: page, dark: dark) }
                }
                write(log)
            }
        }
    }

    private func renderSettings(core: AppCore, page: SettingsPage, dark: Bool) {
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 620, height: 540),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.backgroundColor = .windowBackgroundColor
        w.contentView = NSHostingView(rootView: SettingsView(core: core, page: page))
        w.orderFrontRegardless()
        w.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        snapshot(w, "settings-\(page.rawValue)\(dark ? "-dark" : "").png")
        w.orderOut(nil)
    }

    private func click(_ w: NSWindow, at p: NSPoint, count: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.sendEvent(e)
        }
    }

    private func snapshot(_ w: NSWindow, _ name: String) {
        guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private func write(_ log: [String]) {
        try? log.joined(separator: "\n").write(toFile: dir + "/selftest.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
