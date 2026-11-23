import AppKit
import SwiftUI

/// Debug aid (COPYBOOK_SETUPTEST=<stage>, COPYBOOK_SETUPTEST_DIR=<dir>, with COPYBOOK_TEST_DEFAULTS=1
/// and COPYBOOK_SHOW_SETUP=1): drives the first-run setup with real clicks. "walk" goes through every
/// step. "resume1…4" are run as separate launches, quitting in the middle, to prove that setup picks
/// up at the same step after a restart. Never clicks anything that changes the login item.
extension LayoutTest {
    var setupWindow: NSWindow? { core.setupWindow }
    var setupState: SetupState { core.setupState }

    func captureWindow(_ w: NSWindow, _ name: String) {
        let rect = w.frame.insetBy(dx: -24, dy: -24)
        let primary = NSScreen.screens[0].frame.height
        let cg = CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
        guard let img = CGWindowListCreateImage(cg, .optionIncludingWindow, CGWindowID(w.windowNumber), [.bestResolution]) else {
            check(false, "capture \(name) failed"); return
        }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func setupTexts() async -> [String] { await axAll().filter { $0.role == kAXStaticTextRole }.map { $0.label } }

    func setupButton(_ label: String) async -> CGRect? {
        await axAll().first { $0.role == kAXButtonRole && $0.label == label }?.frame
    }

    func click(_ label: String) async -> Bool {
        guard let f = await setupButton(label) else { return false }
        await realClick(CGPoint(x: f.midX, y: f.midY))
        await wait(0.8)
        return true
    }

    func finishSetupTest() {
        try? log.joined(separator: "\n").appending("\n\nRESULT: \(failures == 0 ? "all checks passed" : "\(failures) FAILED")\n")
            .write(toFile: dir + "/setuptest.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    func runSetup(stage: String) async {
        PanelController.useSavedPlacement = false
        await wait(1.5)
        switch stage {
        case "walk": await setupWalk()
        case "resume1": await setupResume1()
        case "resume2": await setupResume2()
        case "resume3": await setupResume3()
        case "resume4": await setupResume4()
        case "about": await aboutPage()
        default: check(false, "unknown stage \(stage)")
        }
        finishSetupTest()
    }

    private func stepIs(_ s: SetupState.Step) -> Bool { setupState.step == s && Prefs.shared.setupStep == s.rawValue }

    // MARK: Walk through every step

    private func setupWalk() async {
        check(setupWindow?.isVisible == true, "setup opens by itself on a fresh start")
        check(stepIs(.welcome), "starts on the welcome step")
        var t = await setupTexts()
        check(t.contains("Welcome to Copybook"), "welcome: title is shown")
        check(t.contains("Step 1 of 6"), "welcome: shows its place (Step 1 of 6)")
        captureWindow(setupWindow!, "setup-1-welcome-light")
        check(await setupButton("Back") == nil, "welcome: no Back button on the first step")
        check(await setupButton("Skip setup") != nil, "welcome: Skip setup is offered")

        check(await click("Get started"), "welcome: Get started clicked")
        check(stepIs(.access), "→ Paste anywhere (and its position is saved)")
        t = await setupTexts()
        check(t.contains("Paste straight into your apps"), "access: title is shown")
        check(t.contains("Accessibility access"), "access: permission status row is shown")
        let allowed = Paster.isTrusted
        check(t.contains(allowed ? "Allowed. You’re all set." : "Not allowed yet."), "access: status matches the real permission (\(allowed ? "allowed" : "not allowed"))")
        check((await setupButton("Allow…") != nil) == !allowed, "access: the Allow button shows only when not allowed")
        check((await setupButton("Restart Copybook") != nil) == !allowed, "access: the Restart option shows only when not allowed")
        captureWindow(setupWindow!, "setup-2-access-light")

        check(await click("Continue"), "access: Continue clicked")
        check(stepIs(.shortcut), "→ Open it fast")
        t = await setupTexts()
        check(t.contains("Open it from anywhere"), "shortcut: title is shown")
        let sc = Prefs.shared.activateShortcut?.display ?? ""
        check(t.contains("Try it: press \(sc)"), "shortcut: invites you to try \(sc)")
        NotificationCenter.default.post(name: .copybookPanelOpened, object: nil)
        await wait(0.6)
        t = await setupTexts()
        check(t.contains { $0.hasPrefix("It works") }, "shortcut: confirms once the panel has opened")
        captureWindow(setupWindow!, "setup-3-shortcut-light")

        check(await click("Continue"), "shortcut: Continue clicked")
        check(stepIs(.layout), "→ Choose a layout")
        let startVertical = Prefs.shared.verticalLayout
        check(await click("Vertical layout"), "layout: clicked the Vertical card")
        check(Prefs.shared.verticalLayout, "layout: Vertical is now the saved layout")
        captureWindow(setupWindow!, "setup-4-layout-vertical-light")
        check(await click("Horizontal layout"), "layout: clicked the Horizontal card")
        check(!Prefs.shared.verticalLayout, "layout: Horizontal is now the saved layout")
        captureWindow(setupWindow!, "setup-4-layout-horizontal-light")
        Prefs.shared.verticalLayout = startVertical

        check(await click("Back"), "layout: Back clicked")
        check(stepIs(.shortcut), "← back to Open it fast (position saved)")
        check(await click("Continue"), "shortcut: Continue clicked again")
        check(await click("Continue"), "layout: Continue clicked")
        check(stepIs(.preferences), "→ Preferences")
        t = await setupTexts()
        check(t.contains("A few preferences"), "preferences: title is shown")
        let before = Prefs.shared.linkPreviews
        let toggles = await axAll().filter { $0.label == "Link previews" }
        check(!toggles.isEmpty, "preferences: Link previews switch is present")
        if let sw = toggles.first(where: { $0.role == kAXCheckBoxRole || $0.role == "AXSwitch" }) {
            await realClick(CGPoint(x: sw.frame.midX, y: sw.frame.midY)); await wait(0.6)
            check(Prefs.shared.linkPreviews != before, "preferences: clicking the switch changes the setting")
            Prefs.shared.linkPreviews = before
        } else { check(false, "preferences: found a clickable Link previews switch") }
        captureWindow(setupWindow!, "setup-5-preferences-light")

        check(await click("Continue"), "preferences: Continue clicked")
        check(stepIs(.done), "→ All set")
        t = await setupTexts()
        check(t.contains("You’re all set"), "done: title is shown")
        check(t.contains { $0.contains("press") && $0.contains(sc) }, "done: tells you which shortcut to press")
        check(await setupButton("Skip setup") == nil, "done: no Skip button on the last step")
        captureWindow(setupWindow!, "setup-6-done-light")

        check(await click("Start using Copybook"), "done: Start using Copybook clicked")
        check(Prefs.shared.setupCompleted, "finishing marks setup as completed")
        check(setupWindow?.isVisible != true, "the setup window closes")
        check(core.panelController.isVisible, "the panel opens to show you where things are")
        core.panelController.hide(animated: false)

        // ---- Run again from Settings, then skip
        core.restartSetup(); await wait(1.2)
        check(!Prefs.shared.setupCompleted && stepIs(.welcome) && setupWindow?.isVisible == true, "Run Setup Again starts from the beginning")
        check(await click("Skip setup"), "Skip setup clicked")
        check(Prefs.shared.setupCompleted && setupWindow?.isVisible != true, "skipping completes setup and closes the window")

        // ---- Dark appearance: pictures of every step (no accessibility sweeps after this)
        core.restartSetup(); await wait(1.0)
        NSApp.appearance = NSAppearance(named: .darkAqua); await wait(0.8)
        for s in SetupState.Step.allCases {
            setupState.go(to: s); await wait(0.7)
            captureWindow(setupWindow!, "setup-\(s.rawValue + 1)-\(s.title.lowercased().replacingOccurrences(of: " ", with: "-"))-dark")
        }
        NSApp.appearance = nil
        Prefs.shared.setupCompleted = true
        setupWindow?.orderOut(nil)
    }

    // MARK: About page (never clicks Delete Everything)

    private func aboutPage() async {
        core.finishSetup(skipped: true)
        core.openSettings(); await wait(1.2)
        let tabs = await axAll().filter { $0.role == kAXButtonRole || $0.role == kAXStaticTextRole }
        guard let about = tabs.first(where: { $0.label == "About" }) else { check(false, "About tab found"); return }
        await realClick(CGPoint(x: about.frame.midX, y: about.frame.midY)); await wait(2.0)
        let els = await axAll()
        let texts = els.filter { $0.role == kAXStaticTextRole }.map { $0.label }
        check(texts.contains("Where Copybook keeps things"), "about: lists where Copybook keeps things")
        check(texts.contains("Your clips") && texts.contains("Settings"), "about: shows the clips and settings locations")
        check(texts.contains { $0.contains("Library/Application Support/Copybook") }, "about: shows the real clips path")
        check(texts.contains { $0.hasSuffix(" KB") || $0.hasSuffix(" MB") || $0.hasSuffix(" bytes") }, "about: shows sizes")
        check(els.contains { $0.role == kAXButtonRole && $0.label == "Delete Everything…" }, "about: has the Delete Everything button")
        check(els.contains { $0.role == kAXButtonRole && $0.label == "Run Setup…" }, "about: has the Run Setup button")
        check(els.contains { $0.role == kAXButtonRole && $0.label.hasPrefix("Show ") && $0.label.hasSuffix(" in Finder") }, "about: each location can be shown in Finder")
        if let w = NSApp.windows.first(where: { $0.title == "Copybook Settings" && $0.isVisible }) { captureWindow(w, "about-page") }
        if let f = els.first(where: { $0.role == kAXButtonRole && $0.label == "Run Setup…" })?.frame {
            await realClick(CGPoint(x: f.midX, y: f.midY)); await wait(1.2)
            check(setupWindow?.isVisible == true && stepIs(.welcome) && !Prefs.shared.setupCompleted, "about: Run Setup… opens the setup at the beginning")
            core.finishSetup(skipped: true)
        }
        NSApp.windows.filter { $0.title == "Copybook Settings" }.forEach { $0.orderOut(nil) }
    }

    // MARK: Resume across restarts (separate launches)

    private func setupResume1() async {
        check(setupWindow?.isVisible == true && stepIs(.welcome), "launch 1: setup opens at the welcome step")
        check(await click("Get started"), "launch 1: Get started")
        check(await click("Continue"), "launch 1: Continue (access)")
        check(await click("Continue"), "launch 1: Continue (shortcut)")
        check(stepIs(.layout), "launch 1: reached Choose a layout")
        check(await click("Vertical layout"), "launch 1: picked the Vertical layout")
        note("quitting in the middle of setup, as a restart would")
    }

    private func setupResume2() async {
        check(setupWindow?.isVisible == true, "launch 2: setup opens again by itself")
        check(stepIs(.layout), "launch 2: picks up at Choose a layout (step \(setupState.step.rawValue + 1) of 6)")
        check(setupState.resumed, "launch 2: knows it is resuming")
        let t = await setupTexts()
        check(t.contains { $0.hasPrefix("Welcome back") }, "launch 2: says \"Welcome back\"")
        check(Prefs.shared.verticalLayout, "launch 2: the earlier layout choice was kept")
        captureWindow(setupWindow!, "setup-resumed")
        check(await click("Continue"), "launch 2: Continue (layout)")
        check(await click("Continue"), "launch 2: Continue (preferences)")
        check(stepIs(.done), "launch 2: reached All set")
        check(!(await setupTexts()).contains { $0.hasPrefix("Welcome back") }, "launch 2: the welcome-back note goes away once you move on")
        note("quitting again before pressing the last button")
    }

    private func setupResume3() async {
        check(setupWindow?.isVisible == true && stepIs(.done), "launch 3: resumes at All set")
        check(!Prefs.shared.setupCompleted, "launch 3: setup is still unfinished")
        check(await click("Start using Copybook"), "launch 3: Start using Copybook")
        check(Prefs.shared.setupCompleted, "launch 3: setup is now completed")
        core.panelController.hide(animated: false)
    }

    private func setupResume4() async {
        check(Prefs.shared.setupCompleted, "launch 4: setup stays completed")
        check(setupWindow?.isVisible != true, "launch 4: setup does not open again")
        check(Prefs.shared.setupStep == 0, "launch 4: the saved step was cleared")
        Prefs.shared.verticalLayout = false
    }
}
