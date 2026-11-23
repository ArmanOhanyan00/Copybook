import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A quiet, native settings window: a preferences toolbar, one centred column,
// softly grouped rows, system controls and system colours only.

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, privacy, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

private enum S {
    static let column: CGFloat = 480
    static let groupFill = Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.62, darkAlpha: 0.05)
    static let separator = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let selectedTab = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.09)
}

/// Bumped each time the Settings window is opened, so its page starts from the top again.
final class SettingsState: ObservableObject {
    @Published var openToken = 0
}

struct SettingsView: View {
    let core: AppCore
    @ObservedObject var store: Store
    @ObservedObject var state: SettingsState
    @State private var page: SettingsPage
    @Namespace private var tabNS

    init(core: AppCore, page: SettingsPage = .general) {
        self.core = core
        _store = ObservedObject(wrappedValue: core.store)
        _state = ObservedObject(wrappedValue: core.settingsState)
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                Group {
                    switch page {
                    case .general: GeneralPage(core: core, prefs: Prefs.shared, store: store)
                    case .shortcuts: ShortcutsPage(core: core, prefs: Prefs.shared)
                    case .privacy: PrivacyPage(prefs: Prefs.shared)
                    case .about: AboutPage(core: core, store: store)
                    }
                }
                .frame(width: S.column)
                .padding(.top, 6)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            // A fresh scroll view for every page, and every time the window opens, so it
            // always starts from the top instead of keeping the previous page's position.
            .id("\(page.rawValue)-\(state.openToken)")
            .transition(.opacity)
        }
        .frame(width: 620, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.18), value: page)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsPage.allCases) { p in
                ToolbarTab(page: p, selected: page == p, ns: tabNS) {
                    withAnimation(PanelStyle.spring) { page = p }
                }
            }
        }
        .padding(4)
        .glassCapsule()
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }
}

/// One segment of the glass navigation capsule; the selection pill slides between them.
private struct ToolbarTab: View {
    let page: SettingsPage
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: page.symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .symbolVariant(selected ? .fill : .none)
            Text(page.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
        }
        .foregroundStyle(selected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background {
            if selected {
                Capsule().fill(PanelStyle.pill).matchedGeometryEffect(id: "settingsTab", in: ns)
            } else if hovering {
                Capsule().fill(PanelStyle.pill.opacity(0.45))
            }
        }
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

// MARK: - Building blocks

/// A titled group of rows on a soft rounded fill, separated by hairlines.
private struct Section<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(Separated()) { content }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(S.groupFill))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(S.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 22)
    }
}

/// Puts a hairline between each child row.
private struct Separated: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { child in
            child
            if child.id != children.last?.id {
                Rectangle().fill(S.separator).frame(height: 1).padding(.leading, 16)
            }
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, detail == nil ? 11 : 12)
        .frame(minHeight: 44)
    }
}

private struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Row(title: title, detail: detail) {
            // The title is hidden visually (the row shows it) but is what VoiceOver reads.
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

func keyParts(_ s: Shortcut?) -> [String] {
    guard let s else { return ["—"] }
    return s.display.dropLast(s.key.count).map(String.init) + [s.key]
}

// MARK: - General

private struct GeneralPage: View {
    let core: AppCore
    @ObservedObject var prefs: Prefs
    @ObservedObject var store: Store
    @State private var trusted = Paster.isTrusted
    @State private var loginItem = false
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !trusted {
                Section(footer: "Until then, double-clicking an item copies it and you press ⌘V yourself.") {
                    Row(title: "Paste directly into apps", detail: "Allow Copybook under Privacy & Security › Accessibility.") {
                        Button("Allow…") { Paster.requestTrustFromUser() }.buttonStyle(.capsuleProminent)
                    }
                }
                .transition(.opacity)
            }

            Section {
                SwitchRow(title: "Open at login",
                          isOn: Binding(get: { loginItem }, set: { core.opensAtLogin = $0; loginItem = core.opensAtLogin }))
                SwitchRow(title: "Show in menu bar", isOn: $prefs.showMenuBarIcon)
                SwitchRow(title: "Vertical layout", detail: "A tall panel docked to the right edge, with clips stacked top to bottom.",
                          isOn: $prefs.verticalLayout)
                SwitchRow(title: "Paste as plain text", detail: "Leave out fonts, colours and links.", isOn: $prefs.alwaysPlainText)
            }

            Section("Clips", footer: prefs.cardFormat == .cards
                    ? "Cards keep their shape however you resize the panel. In the vertical layout, cards sit side by side wherever there is room."
                    : "One compact row per clip, in either layout.") {
                Row(title: "Show clips as") {
                    PillIconSegmented(options: [("square.grid.2x2", "Cards", CardFormat.cards), ("list.bullet", "List", .list)],
                                      showTitles: true, selection: $prefs.cardFormat)
                }
                if prefs.cardFormat == .cards {
                    Row(title: "Card shape", detail: prefs.cardShape.detail) {
                        PillIconSegmented(options: CardShape.allCases.map { ($0.symbol, "\($0.detail) card", $0) }, selection: $prefs.cardShape)
                    }
                    .transition(.opacity)
                }
            }

            Section("Colour picker", footer: "Picked colours are copied and saved to your history.") {
                Row(title: "Copy colours as") {
                    PillSegmented(options: [("#1E90FF", ScreenColorPicker.Format.hex), ("rgb()", .rgb)],
                                  selection: $prefs.colorFormat)
                }
            }

            Section("History") {
                Row(title: "Keep items for") {
                    PillSegmented(options: [("Day", 1), ("Week", 7), ("Month", 30), ("Year", 365), ("Forever", 0)],
                                  selection: $prefs.retentionDays)
                }
                Row(title: "\(store.items.count) items in history") {
                    Button("Erase…") { core.confirmEraseHistory(fromPanel: false) }
                        .buttonStyle(.capsuleDestructive)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: trusted)
        .animation(.easeOut(duration: 0.2), value: prefs.cardFormat)
        .onAppear { loginItem = core.opensAtLogin; trusted = Paster.isTrusted }
        .onReceive(poll) { _ in trusted = Paster.isTrusted }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPage: View {
    let core: AppCore
    @ObservedObject var prefs: Prefs

    private let reference: [(String, String)] = [
        ("Copy", "Click"),
        ("Paste", "Double-click  or  ↩"),
        ("Paste as plain text", "⇧↩"),
        ("Drop anywhere", "Drag"),
        ("Quick paste", "⌘1 – ⌘9"),
        ("Preview", "Space"),
        ("Edit text", "⌘E"),
        ("Delete", "⌘⌫"),
        ("Search", "Start typing"),
    ]

    private var isDefault: Bool {
        prefs.activateShortcut == .defaultActivate && prefs.stackShortcut == .defaultStack
            && prefs.pickColorShortcut == .defaultPickColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section("Anywhere") {
                Row(title: "Open Copybook") { ShortcutRecorder(shortcut: $prefs.activateShortcut, core: core) }
                Row(title: "Open Stack") { ShortcutRecorder(shortcut: $prefs.stackShortcut, core: core) }
                Row(title: "Pick a colour") { ShortcutRecorder(shortcut: $prefs.pickColorShortcut, core: core) }
            }
            if !isDefault {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        prefs.activateShortcut = .defaultActivate
                        prefs.stackShortcut = .defaultStack
                        prefs.pickColorShortcut = .defaultPickColor
                        core.registerHotKeys()
                    }
                    .buttonStyle(.capsule)
                    .font(.system(size: 12))
                }
                .padding(.top, -12)
                .padding(.bottom, 18)
            }

            Section("In the panel") {
                ForEach(reference, id: \.0) { row in
                    Row(title: row.0) {
                        Text(row.1)
                            .font(.system(size: 12.5, design: .rounded))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let core: AppCore
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut" : (shortcut?.display ?? "None"))
                    .font(.system(size: 12.5, weight: recording ? .regular : .medium, design: .rounded))
                    .foregroundStyle(recording ? Color.accentColor : Color(nsColor: .labelColor))
                    .frame(minWidth: 86)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(S.selectedTab))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help(recording ? "Press Escape to cancel" : "Click to change")

            if shortcut != nil && !recording {
                Button { shortcut = nil; core.registerHotKeys() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        core.suspendHotKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == 53 { stop(); return nil } // Esc cancels
            if let s = Shortcut(event: e) {
                shortcut = s
                stop()
            }
            return nil // a shortcut needs a modifier key; keep listening
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording { recording = false; core.registerHotKeys() }
    }
}

// MARK: - Privacy

private struct PrivacyPage: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section("Don’t save") {
                SwitchRow(title: "Passwords and private items",
                          detail: "Anything a password manager or app marks as confidential.",
                          isOn: $prefs.ignoreConfidential)
                SwitchRow(title: "Temporary items",
                          detail: "Data apps put on the clipboard only for themselves.",
                          isOn: $prefs.ignoreTransient)
            }

            Section {
                SwitchRow(title: "Hide from screenshots and screen sharing",
                          detail: "When on, Copybook can't be captured, so it won't appear in screenshots either.",
                          isOn: Binding(get: { !prefs.showDuringScreenSharing }, set: { prefs.showDuringScreenSharing = !$0 }))
                SwitchRow(title: "Link previews",
                          detail: "Loads each page’s title and image.",
                          isOn: $prefs.linkPreviews)
                SwitchRow(title: "Find text in images",
                          detail: "Makes words in copied images searchable. Stays on this Mac.",
                          isOn: $prefs.recognizeText)
            }

            Section("Ignored apps") {
                ForEach(prefs.ignoredApps, id: \.self) { id in
                    HStack(spacing: 10) {
                        if let icon = AppInfo.icon(for: id) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 20, height: 20)
                                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        }
                        Text(AppInfo.name(for: id) ?? id).font(.system(size: 13))
                        Spacer()
                        Button { prefs.ignoredApps.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                        .buttonStyle(.plain)
                        .help("Stop ignoring")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                }
                Row(title: prefs.ignoredApps.isEmpty ? "No apps ignored" : "") {
                    Button("Add App…") { addApp() }.buttonStyle(.capsule)
                }
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !prefs.ignoredApps.contains(id) { prefs.ignoredApps.append(id) }
        }
    }
}

// MARK: - About

private struct AboutPage: View {
    let core: AppCore
    @ObservedObject var store: Store
    @State private var locations: [Footprint.Location] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                    .padding(.top, 26)
                Text("Copybook").font(.system(size: 20, weight: .semibold))
                    .padding(.top, 6)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Text("Everything you copy, a keystroke away.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 26)

            Section("Setup") {
                Row(title: "Run setup again", detail: "Go through access, shortcuts and layout once more.") {
                    Button("Run Setup…") { core.restartSetup() }.buttonStyle(.capsule)
                }
            }

            Section("Where Copybook keeps things",
                    footer: "Delete Everything removes all of this, along with the login item, the Accessibility permission and the app itself.") {
                if !loaded {
                    Row(title: "Checking…") { ProgressView().controlSize(.small) }
                } else {
                    ForEach(locations) { l in
                        Row(title: l.title, detail: Footprint.abbreviated(l.url)) {
                            HStack(spacing: 10) {
                                Text(Footprint.format(l.bytes))
                                    .font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([l.url])
                                } label: {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Show in Finder")
                                .accessibilityLabel("Show \(l.title) in Finder")
                            }
                        }
                    }
                }
            }

            Section {
                Row(title: "Delete everything", detail: "Removes Copybook and all of its data from this Mac. This can’t be undone.") {
                    Button("Delete Everything…") { core.confirmDeleteEverything() }.buttonStyle(.capsuleDestructive)
                }
            }

            Text("An independent, open-source project.")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .task {
            // Measured off the main thread: the clips folder can be large.
            locations = await Task.detached { Footprint.measured(in: .live()) }.value
            loaded = true
        }
    }
}
