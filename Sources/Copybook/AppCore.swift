import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Central coordinator: owns the store, monitor, panels and every user action.
@MainActor
final class AppCore: NSObject, NSMenuDelegate {
    static let shared = AppCore()

    let store = Store()
    let model = PanelModel()
    let prefs = Prefs.shared
    private(set) lazy var monitor = ClipboardMonitor(store: store)
    private(set) lazy var panelController = PanelController(core: self)
    private(set) lazy var preview = PreviewController(core: self)
    private(set) lazy var stack = StackController(core: self)
    private(set) lazy var colorPicker = ScreenColorPicker(core: self)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private(set) var setupWindow: NSWindow?
    private(set) lazy var setupState = SetupState()
    /// True from the moment "Delete Everything" is confirmed; nothing may be written to disk after it.
    private(set) var isUninstalling = false
    let settingsState = SettingsState()
    private var editorWindows: [UUID: NSWindow] = [:]
    private var pendingTouch: [UUID] = []

    private var observers: [Any] = []

    private enum HotKeyID: UInt32 { case activate = 1, stack = 2, pickColor = 3 }

    func start() {
        monitor.onCapture = { [weak self] item in self?.stack.didCapture(item) }
        monitor.start()
        registerHotKeys()
        updateStatusItem()
        store.prune(days: prefs.retentionDays)
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.store.prune(days: self.prefs.retentionDays) }
        }
        observers.append(prefs.$showMenuBarIcon.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        })
        observers.append(prefs.$verticalLayout.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.panelController.layoutPreferenceChanged() }
        })
        observers.append(prefs.$cardFormat.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.panelController.cardStyleChanged() }
        })
        observers.append(prefs.$cardShape.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.panelController.cardStyleChanged() }
        })
        observers.append(prefs.$retentionDays.dropFirst().sink { [weak self] days in
            DispatchQueue.main.async { self?.store.prune(days: days) }
        })

    }

    // MARK: Hotkeys & menu bar

    func registerHotKeys() {
        HotKeyCenter.shared.register(id: HotKeyID.activate.rawValue, shortcut: prefs.activateShortcut) { [weak self] in
            self?.panelController.toggle()
        }
        HotKeyCenter.shared.register(id: HotKeyID.stack.rawValue, shortcut: prefs.stackShortcut) { [weak self] in
            self?.stack.toggle()
        }
        HotKeyCenter.shared.register(id: HotKeyID.pickColor.rawValue, shortcut: prefs.pickColorShortcut) { [weak self] in
            self?.pickColor()
        }
    }

    func pickColor() { colorPicker.pick() }

    /// Switches between the horizontal bar and the vertical, side-docked panel.
    func toggleLayout() { prefs.verticalLayout.toggle() }

    func suspendHotKeys() { HotKeyCenter.shared.unregisterAll() }

    func updateStatusItem() {
        guard prefs.showMenuBarIcon else {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            s.menu = menu
            statusItem = s
        }
        statusItem?.button?.image = MenuBarIcon.image(paused: prefs.isPaused)
        statusItem?.button?.toolTip = prefs.isPaused ? "Copybook — capturing paused" : "Copybook"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = menu.addItem(withTitle: "Open Copybook", action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        if let s = prefs.activateShortcut { open.title += "    \(s.display)" }
        let stackItem = menu.addItem(withTitle: stack.isActive ? "Close Stack" : "Open Stack", action: #selector(menuStack), keyEquivalent: "")
        stackItem.target = self
        if !prefs.setupCompleted {
            let setup = menu.addItem(withTitle: "Finish Setup…", action: #selector(menuSetup), keyEquivalent: "")
            setup.target = self
            menu.addItem(.separator())
        }
        let layout = menu.addItem(withTitle: prefs.verticalLayout ? "Horizontal Layout" : "Vertical Layout", action: #selector(menuLayout), keyEquivalent: "")
        layout.target = self
        let pick = menu.addItem(withTitle: "Pick Colour", action: #selector(menuPickColor), keyEquivalent: "")
        pick.target = self
        if let s = prefs.pickColorShortcut { pick.title += "    \(s.display)" }
        menu.addItem(.separator())
        if prefs.isPaused {
            let until = prefs.pausedUntil ?? Date()
            let title = until > Date().addingTimeInterval(86_400 * 365)
                ? "Paused" : "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Resume", action: #selector(menuResume), keyEquivalent: "").target = self
        } else {
            let pause = NSMenuItem(title: "Pause Capturing", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, minutes) in [("For 15 Minutes", 15), ("For 1 Hour", 60), ("For 8 Hours", 480), ("Until Resumed", 0)] {
                let i = sub.addItem(withTitle: title, action: #selector(menuPause(_:)), keyEquivalent: "")
                i.target = self
                i.tag = minutes
            }
            pause.submenu = sub
            menu.addItem(pause)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Copybook", action: #selector(menuQuit), keyEquivalent: "q").target = self
    }

    @objc private func menuOpen() { panelController.show() }
    @objc private func menuStack() { stack.toggle() }
    @objc private func menuSetup() { showSetup() }
    @objc private func menuLayout() { toggleLayout() }
    // After the menu has closed, so the loupe isn't fighting the menu's tracking.
    @objc private func menuPickColor() { DispatchQueue.main.async { self.pickColor() } }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuResume() { resume() }
    @objc private func menuPause(_ sender: NSMenuItem) { pause(minutes: sender.tag) }

    func pause(minutes: Int) {
        prefs.pausedUntil = minutes == 0 ? .distantFuture : Date().addingTimeInterval(Double(minutes) * 60)
        updateStatusItem()
        if minutes > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes) * 60 + 1) { [weak self] in self?.updateStatusItem() }
        }
    }

    func resume() {
        prefs.pausedUntil = nil
        updateStatusItem()
    }

    // MARK: Visible items & selection

    func visibleItems() -> [ClipItem] {
        let tokens = model.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return store.items.filter { item in
            if let t = model.typeFilter, item.kind != t { return false }
            if let a = model.appFilter, item.sourceBundleID != a { return false }
            return tokens.isEmpty || item.matches(tokens)
        }
    }

    /// Selected clips in on-screen order (falls back to the cursor).
    func selection() -> [ClipItem] {
        let visible = visibleItems()
        let picked = visible.filter { model.selectedIDs.contains($0.id) }
        if !picked.isEmpty { return picked }
        return visible.filter { $0.id == model.cursorID }
    }

    /// Context-menu targets: the selection if the clicked clip is part of it, otherwise just that clip.
    func targets(for item: ClipItem) -> [ClipItem] {
        model.selectedIDs.contains(item.id) ? selection() : [item]
    }

    func resetCursorToFirst() { model.select(visibleItems().first?.id) }

    func moveCursor(_ delta: Int, extend: Bool, toEnd: Bool) {
        let items = visibleItems()
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == model.cursorID } ?? -1
        var next = toEnd ? (delta < 0 ? 0 : items.count - 1) : current + delta
        next = max(0, min(items.count - 1, next))
        let id = items[next].id
        if extend, let anchor = model.anchorID, let a = items.firstIndex(where: { $0.id == anchor }) {
            model.selectedIDs = Set(items[min(a, next)...max(a, next)].map(\.id))
            model.cursorID = id
        } else {
            model.select(id)
        }
        if preview.isVisible { preview.show(items[next]) }
    }

    func click(_ item: ClipItem) {
        let (clickCount, flags) = panelController.lastClick
        click(item, clickCount: clickCount, flags: flags)
    }

    func click(_ item: ClipItem, clickCount: Int, flags: NSEvent.ModifierFlags) {
        if clickCount >= 2 {
            paste(targets(for: item))
            return
        }
        if flags.contains(.command) {
            if model.selectedIDs.contains(item.id) { model.selectedIDs.remove(item.id) } else { model.selectedIDs.insert(item.id) }
            model.cursorID = item.id
        } else if flags.contains(.shift), let anchor = model.anchorID {
            let items = visibleItems()
            if let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
                model.selectedIDs = Set(items[min(a, b)...max(a, b)].map(\.id))
            }
            model.cursorID = item.id
        } else {
            model.select(item.id)
            copyInPlace([item])
        }
        if preview.isVisible { preview.show(item) }
    }

    /// Shows a short confirmation badge on a card.
    func flash(_ id: UUID?, _ message: String, symbol: String = "checkmark.circle.fill") {
        guard let id else { return }
        let f = PanelModel.Flash(id: id, message: message, symbol: symbol)
        withAnimation(Theme.snappy) { model.flash = f }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.model.flash?.token == f.token else { return }
            withAnimation(Theme.gentle) { self.model.flash = nil }
        }
    }

    // MARK: Paste / copy

    func pasteSelection(plain: Bool) { paste(selection(), plain: plain) }

    func quickPaste(index: Int) {
        let items = visibleItems()
        guard index < items.count else { return }
        paste([items[index]])
    }

    func paste(_ items: [ClipItem], plain: Bool = false) {
        guard !items.isEmpty else { return }
        // Without Accessibility we can't press ⌘V for the user: copy instead, keep the
        // panel open and explain inline. No system prompt is ever shown automatically.
        guard Paster.isTrusted else {
            copyInPlace(items, plain: plain)
            withAnimation(Theme.snappy) { model.showAccessNotice = true }
            return
        }
        let usePlain = plain || prefs.alwaysPlainText
        if model.pinned {
            // A pinned panel stays open. The app you were typing in is still the frontmost one (the panel
            // never took over), so hand it focus back, then press ⌘V there.
            monitor.ignore(changeCount: Paster.write(items, store: store, plain: usePlain))
            store.touch(items.map(\.id))
            let target = NSWorkspace.shared.frontmostApplication
            if NSApp.isActive { NSApp.deactivate() }
            if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier { target.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { Paster.sendCommandV() }
            return
        }
        panelController.hide(animated: false)
        let wasActive = NSApp.isActive
        if wasActive { NSApp.hide(nil) }
        monitor.ignore(changeCount: Paster.write(items, store: store, plain: usePlain))
        store.touch(items.map(\.id))
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasActive ? 0.25 : 0.05)) { Paster.sendCommandV() }
    }

    func copySelection() { copyInPlace(selection()) }

    /// Puts clips on the clipboard and keeps the panel open. The clips move to the
    /// top of history when the panel closes, so cards don't jump under the cursor.
    func copyInPlace(_ items: [ClipItem], plain: Bool = false) {
        guard !items.isEmpty else { return }
        monitor.ignore(changeCount: Paster.write(items, store: store, plain: plain || prefs.alwaysPlainText))
        pendingTouch.append(contentsOf: items.map(\.id))
        flash(items.last?.id, items.count > 1 ? "Copied \(items.count)" : "Copied")
    }

    func flushPendingTouches() {
        guard !pendingTouch.isEmpty else { return }
        store.touch(pendingTouch)
        pendingTouch.removeAll()
    }

    // MARK: Item actions

    func deleteSelection() {
        let items = visibleItems()
        let doomed = Set(selection().map(\.id))
        guard !doomed.isEmpty else { return }
        let lastIndex = items.lastIndex { doomed.contains($0.id) } ?? 0
        let next = items[(lastIndex + 1)...].first { !doomed.contains($0.id) }
            ?? items[..<lastIndex].last { !doomed.contains($0.id) }
        withAnimation(Theme.snappy) { store.delete(doomed) }
        model.select(next?.id)
        if preview.isVisible { if let next { preview.show(next) } else { preview.hide() } }
    }

    func delete(_ items: [ClipItem]) {
        let ids = Set(items.map(\.id))
        withAnimation(Theme.snappy) { store.delete(ids) }
        if let c = model.cursorID, ids.contains(c) { resetCursorToFirst() }
    }

    func togglePreview() {
        if preview.isVisible { preview.hide(); return }
        guard let item = selection().last else { return }
        preview.show(item)
    }

    func open(_ item: ClipItem) {
        panelController.hide()
        if let url = item.linkURL { NSWorkspace.shared.open(url) }
        else if let paths = item.filePaths { paths.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) } }
    }

    func reveal(_ item: ClipItem) {
        panelController.hide()
        NSWorkspace.shared.activateFileViewerSelecting((item.filePaths ?? []).map { URL(fileURLWithPath: $0) })
    }

    func editCursor() {
        guard let item = selection().last else { return }
        edit(item)
    }

    func edit(_ item: ClipItem) {
        guard item.kind.isTextual else { return }
        panelController.hide()
        if let w = editorWindows[item.id] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let id = item.id
        let view = EditorView(initial: item.text ?? "", title: item.headerTitle) { [weak self] text in
            if let text { self?.store.updateText(id, text: text) }
            self?.editorWindows[id]?.close()
            self?.editorWindows[id] = nil
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Edit \(item.kind.label)"
        w.contentViewController = NSHostingController(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        editorWindows[id] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func startRename(_ item: ClipItem) {
        model.select(item.id)
        model.renamingItemID = item.id
    }

    func commitRename(_ id: UUID, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.mutate(id) { $0.title = t.isEmpty ? nil : t }
        model.renamingItemID = nil
        model.focusToken += 1
    }

    func newTextItem() {
        let item = store.addTextItem("")
        model.select(item.id)
        edit(item)
    }

    func addSelectionToStack() { stack.add(selection()) }

    func confirmEraseHistory(fromPanel: Bool) {
        let run = { () -> Bool in
            let a = NSAlert()
            a.messageText = "Erase your clipboard history?"
            a.informativeText = "Every clip will be deleted. This can’t be undone."
            a.addButton(withTitle: "Erase")
            a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            return a.runModal() == .alertFirstButtonReturn
        }
        let ok = fromPanel ? panelController.withModal(run) : run()
        if ok { store.eraseHistory(); resetCursorToFirst() }
    }

    // MARK: Windows

    func openSettings() {
        panelController.hide()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Copybook Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = .windowBackgroundColor
            w.contentViewController = NSHostingController(rootView: SettingsView(core: self))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsState.openToken += 1
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Setup

    /// Opens the first-run setup at the step it was last on.
    func showSetup() {
        panelController.hide()
        setupState.reload()
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Set Up Copybook"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.backgroundColor = .windowBackgroundColor
            w.contentViewController = NSHostingController(rootView: SetupView(core: self, state: setupState, prefs: prefs))
            w.isReleasedWhenClosed = false
            w.center()
            setupWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// Ends the setup (finished or skipped) so it doesn't come back at the next launch.
    func finishSetup(skipped: Bool) {
        prefs.setupCompleted = true
        prefs.setupStep = 0
        setupWindow?.orderOut(nil)
        if !skipped { panelController.show() }
    }

    /// Runs the setup again from the start (from Settings).
    func restartSetup() {
        prefs.setupCompleted = false
        prefs.setupStep = 0
        settingsWindow?.orderOut(nil)
        showSetup()
    }

    /// Quits and starts the app again. Setup progress is already saved, so it resumes where it was.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; open -n \"$1\"", "sh", Bundle.main.bundleURL.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Delete everything

    /// Asks, then removes the app and everything it has stored on this Mac.
    func confirmDeleteEverything() {
        let env = Footprint.Environment.live()
        let plan = Footprint.plan(in: env)
        let a = makeDeleteAlert(plan: plan)
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return }
        deleteEverything(plan: plan, env: env)
    }

    /// The confirmation. Cancel is the default (Return) button; deleting takes a deliberate click.
    func makeDeleteAlert(plan: Footprint.Plan) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Delete Copybook and everything it has stored?"
        a.informativeText = deleteSummary(plan: plan)
        let cancel = a.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let go = a.addButton(withTitle: "Delete Everything")
        go.hasDestructiveAction = true
        go.keyEquivalent = ""
        return a
    }

    /// What the confirmation says will be deleted, built from the real plan.
    func deleteSummary(plan: Footprint.Plan) -> String {
        let clips = store.items.count
        let size = plan.items.filter { $0.kind == .clips }.reduce(Int64(0)) { $0 + Footprint.size(of: $1.url) }
        let apps = plan.items.filter { $0.kind == .app }.map { Footprint.abbreviated($0.url) }
        return """
        This permanently deletes:

        • your clips (\(clips.formatted()) saved, \(Footprint.format(size)))
        • Copybook's settings, caches and temporary files
        • the login item and the Accessibility permission
        • the app itself\(apps.isEmpty ? "" : ": " + apps.joined(separator: ", "))

        This can’t be undone.
        """
    }

    /// The deletion itself (no questions asked): stops the app writing anything, removes the
    /// login item, then deletes every location in the footprint and quits. A helper finishes the
    /// parts that can only be removed once the app has exited.
    func deleteEverything(plan: Footprint.Plan, env: Footprint.Environment) {
        isUninstalling = true
        panelController.hide(animated: false, force: true)
        preview.hide()
        if stack.isActive { stack.toggle() }
        monitor.stop()
        store.freeze()
        HotKeyCenter.shared.unregisterAll()
        if opensAtLogin { opensAtLogin = false }
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }
        setupWindow?.orderOut(nil)
        settingsWindow?.orderOut(nil)
        UserDefaults.standard.removePersistentDomain(forName: env.bundleID)
        let outcome = Footprint.execute(plan, in: env)

        let done = NSAlert()
        done.messageText = outcome.failed.isEmpty ? "Copybook has been removed" : "Copybook was removed, except for a few items"
        var text = "Everything it stored on this Mac is gone. The app removes itself as it quits."
        if !outcome.failed.isEmpty {
            text += "\n\nCouldn’t remove:\n" + outcome.failed.map { "• " + ($0.0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
        }
        done.informativeText = text
        done.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        done.runModal()
        exit(0)   // not a normal quit: that would save the clips again
    }

    // MARK: Login item

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSLog("Copybook: login item change failed: \(error)") }
        }
    }
}
