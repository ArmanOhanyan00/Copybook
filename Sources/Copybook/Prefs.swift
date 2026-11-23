import AppKit

final class Prefs: ObservableObject {
    static let shared = Prefs()
    /// Test runs (COPYBOOK_TEST_DEFAULTS) use their own settings store, never the user's.
    private let d: UserDefaults = {
        if ProcessInfo.processInfo.environment["COPYBOOK_TEST_DEFAULTS"] != nil, let suite = UserDefaults(suiteName: "local.copybook.test") {
            // Two-stage tests (quit and relaunch) keep their settings between runs.
            if ProcessInfo.processInfo.environment["COPYBOOK_TEST_KEEP_DEFAULTS"] == nil {
                suite.removePersistentDomain(forName: "local.copybook.test")
            }
            return suite
        }
        return .standard
    }()

    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: "retentionDays") } }
    @Published var pasteToActiveApp: Bool { didSet { d.set(pasteToActiveApp, forKey: "pasteToActiveApp") } }
    @Published var alwaysPlainText: Bool { didSet { d.set(alwaysPlainText, forKey: "alwaysPlainText") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    @Published var ignoreConfidential: Bool { didSet { d.set(ignoreConfidential, forKey: "ignoreConfidential") } }
    @Published var ignoreTransient: Bool { didSet { d.set(ignoreTransient, forKey: "ignoreTransient") } }
    @Published var linkPreviews: Bool { didSet { d.set(linkPreviews, forKey: "linkPreviews") } }
    @Published var recognizeText: Bool { didSet { d.set(recognizeText, forKey: "recognizeText") } }
    /// Vertical layout: a tall panel docked to the right edge, cards stacked top to bottom.
    @Published var verticalLayout: Bool { didSet { d.set(verticalLayout, forKey: "verticalLayout") } }
    /// Clips as cards or as a compact list, and (for cards) their shape.
    @Published var cardFormat: CardFormat { didSet { d.set(cardFormat.rawValue, forKey: "cardFormat") } }
    @Published var cardShape: CardShape { didSet { d.set(cardShape.rawValue, forKey: "cardShape") } }
    /// First-run setup: done (or skipped), and which step it was on, so it can resume after a restart.
    @Published var setupCompleted: Bool { didSet { d.set(setupCompleted, forKey: "setupCompleted") } }
    @Published var setupStep: Int { didSet { d.set(setupStep, forKey: "setupStep") } }
    @Published var showDuringScreenSharing: Bool { didSet { d.set(showDuringScreenSharing, forKey: "showDuringScreenSharing") } }
    @Published var ignoredApps: [String] { didSet { d.set(ignoredApps, forKey: "ignoredApps") } }
    @Published var activateShortcut: Shortcut? { didSet { store(activateShortcut, "activateShortcut") } }
    @Published var stackShortcut: Shortcut? { didSet { store(stackShortcut, "stackShortcut") } }
    @Published var pickColorShortcut: Shortcut? { didSet { store(pickColorShortcut, "pickColorShortcut") } }
    /// How picked colours are written: "#1E90FF" or "rgb(30, 144, 255)".
    @Published var colorFormat: ScreenColorPicker.Format { didSet { d.set(colorFormat.rawValue, forKey: "colorFormat") } }
    @Published var pausedUntil: Date? { didSet { d.set(pausedUntil, forKey: "pausedUntil") } }
    /// The panel's frame when the user chose "Always" after moving or resizing it.
    @Published var panelFrame: NSRect? {
        didSet { d.set(panelFrame.map(NSStringFromRect), forKey: "panelFrame") }
    }

    /// The same, for the vertical layout.
    @Published var panelFrameVertical: NSRect? {
        didSet { d.set(panelFrameVertical.map(NSStringFromRect), forKey: "panelFrameVertical") }
    }

    var isPaused: Bool {
        guard let p = pausedUntil else { return false }
        return p > Date()
    }

    private init() {
        d.register(defaults: [
            "retentionDays": 30,
            "pasteToActiveApp": true,
            "alwaysPlainText": false,
            "showMenuBarIcon": true,
            "ignoreConfidential": true,
            "ignoreTransient": true,
            "linkPreviews": true,
            "recognizeText": true,
            "showDuringScreenSharing": true,
            "verticalLayout": false,
            "ignoredApps": ["com.apple.keychainaccess", "com.apple.Passwords"],
        ])
        retentionDays = d.integer(forKey: "retentionDays")
        pasteToActiveApp = d.bool(forKey: "pasteToActiveApp")
        alwaysPlainText = d.bool(forKey: "alwaysPlainText")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        ignoreConfidential = d.bool(forKey: "ignoreConfidential")
        ignoreTransient = d.bool(forKey: "ignoreTransient")
        linkPreviews = d.bool(forKey: "linkPreviews")
        recognizeText = d.bool(forKey: "recognizeText")
        // One-time change: Copybook used to hide itself from screenshots by default.
        if !d.bool(forKey: "migratedScreenCaptureDefault") {
            d.set(true, forKey: "showDuringScreenSharing")
            d.set(true, forKey: "migratedScreenCaptureDefault")
        }
        showDuringScreenSharing = d.bool(forKey: "showDuringScreenSharing")
        ignoredApps = d.stringArray(forKey: "ignoredApps") ?? []
        pausedUntil = d.object(forKey: "pausedUntil") as? Date
        panelFrame = d.string(forKey: "panelFrame").map(NSRectFromString)
        panelFrameVertical = d.string(forKey: "panelFrameVertical").map(NSRectFromString)
        setupCompleted = d.bool(forKey: "setupCompleted")
        setupStep = d.integer(forKey: "setupStep")
        verticalLayout = d.bool(forKey: "verticalLayout")
        if ProcessInfo.processInfo.environment["COPYBOOK_START_VERTICAL"] != nil { verticalLayout = true }
        cardFormat = CardFormat(rawValue: d.string(forKey: "cardFormat") ?? "") ?? .cards
        cardShape = CardShape(rawValue: d.string(forKey: "cardShape") ?? "") ?? .automatic
        if let v = ProcessInfo.processInfo.environment["COPYBOOK_START_SHAPE"], let shape = CardShape(rawValue: v) { cardShape = shape }
        if ProcessInfo.processInfo.environment["COPYBOOK_START_LIST"] != nil { cardFormat = .list }
        activateShortcut = Prefs.load("activateShortcut", default: .defaultActivate, from: d)
        stackShortcut = Prefs.load("stackShortcut", default: .defaultStack, from: d)
        pickColorShortcut = Prefs.load("pickColorShortcut", default: .defaultPickColor, from: d)
        colorFormat = ScreenColorPicker.Format(rawValue: d.string(forKey: "colorFormat") ?? "") ?? .hex
    }

    private func store(_ s: Shortcut?, _ key: String) {
        if let s, let data = try? JSONEncoder().encode(s) {
            d.set(data, forKey: key)
        } else {
            d.set(Data(), forKey: key) // empty = explicitly cleared
        }
    }

    private static func load(_ key: String, default def: Shortcut, from d: UserDefaults) -> Shortcut? {
        guard let data = d.data(forKey: key) else { return def }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? def
    }
}
