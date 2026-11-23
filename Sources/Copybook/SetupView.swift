import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted whenever the panel opens (the setup uses it to confirm the shortcut works).
    static let copybookPanelOpened = Notification.Name("local.copybook.panelOpened")
}

/// Where the first-run setup is. Every change is saved at once, so quitting or restarting the
/// app in the middle (for a permission, say) picks up at the same step.
@MainActor
final class SetupState: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, access, shortcut, layout, preferences, done
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .access: return "Paste anywhere"
            case .shortcut: return "Open it fast"
            case .layout: return "Choose a layout"
            case .preferences: return "Preferences"
            case .done: return "All set"
            }
        }
    }

    @Published private(set) var step: Step
    /// The window opened on a step that was already in progress (after a quit or restart).
    @Published var resumed: Bool
    @Published var trusted = Paster.isTrusted
    @Published var panelOpened = false

    init() {
        let saved = Prefs.shared.setupStep
        step = Step(rawValue: min(max(saved, 0), Step.allCases.count - 1)) ?? .welcome
        resumed = saved > 0
    }

    /// Reads the saved position again (when the window is reopened).
    func reload() {
        let saved = Prefs.shared.setupStep
        step = Step(rawValue: min(max(saved, 0), Step.allCases.count - 1)) ?? .welcome
        resumed = saved > 0
    }

    func go(to s: Step) {
        resumed = false
        withAnimation(.easeOut(duration: 0.22)) { step = s }
        Prefs.shared.setupStep = s.rawValue
    }

    func next() { if let n = Step(rawValue: step.rawValue + 1) { go(to: n) } }
    func back() { if let p = Step(rawValue: step.rawValue - 1) { go(to: p) } }
    var isFirst: Bool { step == .welcome }
    var isLast: Bool { step == .done }
}

struct SetupView: View {
    let core: AppCore
    @ObservedObject var state: SetupState
    @ObservedObject var prefs: Prefs
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 30)
            ZStack {
                content
                    .id(state.step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(poll) { _ in state.trusted = Paster.isTrusted }
        .onReceive(NotificationCenter.default.publisher(for: .copybookPanelOpened)) { _ in
            if state.step == .shortcut { withAnimation { state.panelOpened = true } }
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                ForEach(SetupState.Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= state.step.rawValue ? PanelStyle.accent : PanelStyle.pill)
                        .frame(width: s == state.step ? 26 : 8, height: 6)
                        .animation(.easeOut(duration: 0.22), value: state.step)
                }
            }
            if state.resumed {
                Label("Welcome back. Picking up where you left off.", systemImage: "arrow.uturn.forward")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PanelStyle.secondary)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(PanelStyle.pill))
                    .transition(.opacity)
            } else {
                Text("Step \(state.step.rawValue + 1) of \(SetupState.Step.allCases.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(PanelStyle.tertiary)
                    .frame(height: 26)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !state.isFirst {
                Button("Back") { state.back() }.buttonStyle(.capsule)
            }
            Spacer()
            if !state.isLast {
                Button("Skip setup") { core.finishSetup(skipped: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PanelStyle.secondary)
                    .padding(.trailing, 6)
            }
            Button(continueTitle) {
                if state.isLast { core.finishSetup(skipped: false) } else { state.next() }
            }
            .buttonStyle(.capsuleProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .padding(.top, 10)
    }

    private var continueTitle: String {
        switch state.step {
        case .welcome: return "Get started"
        case .done: return "Start using Copybook"
        default: return "Continue"
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case .welcome: welcome
        case .access: access
        case .shortcut: shortcut
        case .layout: layout
        case .preferences: preferences
        case .done: done
        }
    }

    private func page<Body: View>(symbol: String? = nil, title: String, text: String, @ViewBuilder body: () -> Body) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(PanelStyle.accent)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(PanelStyle.accent.opacity(0.12)))
            } else {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            }
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 18)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(PanelStyle.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
                .padding(.top, 8)
            body()
                .padding(.top, 24)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 40)
    }

    private var welcome: some View {
        page(title: "Welcome to Copybook", text: "Everything you copy is kept, searchable and one click away. A short setup gets it ready.") {
            VStack(alignment: .leading, spacing: 14) {
                bullet("doc.on.clipboard", "Copy anything", "Text, links, images, files and colours are saved automatically.")
                bullet("cursorarrow.click.2", "Click, double-click or drag", "Click to copy, double-click to paste, drag to drop anywhere.")
                bullet("lock", "Private by design", "Everything stays on this Mac. Passwords are skipped.")
            }
            .frame(maxWidth: 400, alignment: .leading)
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PanelStyle.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.system(size: 12.5)).foregroundStyle(PanelStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var access: some View {
        page(symbol: "hand.point.up.left", title: "Paste straight into your apps",
             text: "To press ⌘V for you when you double-click a clip, Copybook needs Accessibility access. Without it, double-click copies and you press ⌘V yourself.") {
            VStack(spacing: 14) {
                SetupCard {
                    HStack(spacing: 12) {
                        Image(systemName: state.trusted ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 20))
                            .foregroundStyle(state.trusted ? Color(nsColor: .systemGreen) : PanelStyle.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility access").font(.system(size: 13.5, weight: .semibold))
                            Text(state.trusted ? "Allowed. You’re all set." : "Not allowed yet.")
                                .font(.system(size: 12.5)).foregroundStyle(PanelStyle.secondary)
                        }
                        Spacer()
                        if !state.trusted {
                            Button("Allow…") { Paster.requestTrustFromUser() }.buttonStyle(.capsuleProminent)
                        }
                    }
                }
                if !state.trusted {
                    Text("In System Settings, switch Copybook on. If it doesn't take effect, restart Copybook; setup will pick up right here.")
                        .font(.system(size: 12))
                        .foregroundStyle(PanelStyle.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Restart Copybook") { core.relaunch() }.buttonStyle(.capsule)
                }
            }
            .frame(maxWidth: 400)
        }
    }

    private var shortcut: some View {
        page(symbol: "command", title: "Open it from anywhere",
             text: "Pick the keys that open Copybook over whatever you're doing. You can change these later in Settings.") {
            VStack(spacing: 14) {
                SetupCard {
                    VStack(spacing: 0) {
                        SetupRow("Open Copybook") { ShortcutRecorder(shortcut: $prefs.activateShortcut, core: core) }
                        SetupDivider()
                        SetupRow("Open Stack") { ShortcutRecorder(shortcut: $prefs.stackShortcut, core: core) }
                        SetupDivider()
                        SetupRow("Pick a colour") { ShortcutRecorder(shortcut: $prefs.pickColorShortcut, core: core) }
                    }
                }
                if let s = prefs.activateShortcut {
                    HStack(spacing: 8) {
                        Image(systemName: state.panelOpened ? "checkmark.circle.fill" : "keyboard")
                            .foregroundStyle(state.panelOpened ? Color(nsColor: .systemGreen) : PanelStyle.tertiary)
                        Text(state.panelOpened ? "It works. Close the panel with Esc." : "Try it: press \(s.display)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PanelStyle.secondary)
                    }
                    .frame(height: 24)
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private var layout: some View {
        page(symbol: "rectangle.landscape.rotate", title: "Choose a layout",
             text: "A bar along the bottom of the screen, or a tall panel on the right edge. Switch any time from the panel or Settings.") {
            HStack(spacing: 16) {
                LayoutChoice(title: "Horizontal", subtitle: "Along the bottom", vertical: false, selected: !prefs.verticalLayout) { prefs.verticalLayout = false }
                LayoutChoice(title: "Vertical", subtitle: "Down the right edge", vertical: true, selected: prefs.verticalLayout) { prefs.verticalLayout = true }
            }
        }
    }

    private var preferences: some View {
        page(symbol: "slider.horizontal.3", title: "A few preferences",
             text: "Sensible defaults are already on. Change anything now or later in Settings.") {
            SetupCard {
                VStack(spacing: 0) {
                    SetupRow("Open at login") {
                        Toggle("Open at login", isOn: Binding(get: { core.opensAtLogin }, set: { core.opensAtLogin = $0 }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    SetupDivider()
                    SetupRow("Link previews") {
                        Toggle("Link previews", isOn: $prefs.linkPreviews).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    SetupDivider()
                    SetupRow("Hide from screenshots") {
                        Toggle("Hide from screenshots and screen sharing", isOn: Binding(get: { !prefs.showDuringScreenSharing }, set: { prefs.showDuringScreenSharing = !$0 }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    SetupDivider()
                    SetupRow("Keep clips for") {
                        PillSegmented(options: [("Day", 1), ("Week", 7), ("Month", 30), ("Year", 365), ("Forever", 0)],
                                      selection: $prefs.retentionDays)
                    }
                }
            }
            .frame(maxWidth: 470)
        }
    }

    private var done: some View {
        page(title: "You’re all set", text: "Copy something, then press \(prefs.activateShortcut?.display ?? "your shortcut") to see it here.") {
            SetupCard {
                VStack(spacing: 0) {
                    summaryRow("Layout", prefs.verticalLayout ? "Vertical, down the right edge" : "Horizontal, along the bottom")
                    SetupDivider()
                    summaryRow("Open Copybook", prefs.activateShortcut?.display ?? "No shortcut")
                    SetupDivider()
                    summaryRow("Paste into apps", state.trusted ? "Allowed" : "Not allowed. You'll press ⌘V yourself")
                }
            }
            .frame(maxWidth: 400)
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        SetupRow(title) { Text(value).font(.system(size: 12.5)).foregroundStyle(PanelStyle.secondary) }
    }
}

// MARK: - Small building blocks

private struct SetupCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 16).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.62, darkAlpha: 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09), lineWidth: 0.5))
    }
}

private struct SetupRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.trailing = trailing() }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13.5)).fixedSize()
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 42)
    }
}

private struct SetupDivider: View {
    var body: some View { Rectangle().fill(Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)).frame(height: 1) }
}

/// A selectable mini picture of one layout.
private struct LayoutChoice: View {
    let title: String
    let subtitle: String
    let vertical: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                screen
                    .frame(width: 176, height: 112)
                VStack(spacing: 1) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(PanelStyle.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(selected ? PanelStyle.accent.opacity(0.10) : PanelStyle.pill.opacity(hovering ? 1 : 0.6)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? PanelStyle.accent : Color.clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if selected {
                    // A badge on the card's corner, clear of the picture.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(PanelStyle.accent)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(1))
                        .offset(x: 7, y: -7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title) layout")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A tiny desktop with the panel drawn where it would sit.
    private var screen: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dynamic(light: 0xD9DCE3, dark: 0x2A2C33))
            if vertical {
                HStack { Spacer(); panelShape(width: 52, height: 96, cards: 3, tall: true).padding(.trailing, 8) }
            } else {
                VStack { Spacer(); panelShape(width: 160, height: 44, cards: 4, tall: false).padding(.bottom, 8) }
            }
        }
    }

    private func panelShape(width: CGFloat, height: CGFloat, cards: Int, tall: Bool) -> some View {
        let card = RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.9))
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.dynamic(light: 0xF3F1EE, dark: 0x3A3A40))
            .frame(width: width, height: height)
            .overlay {
                if tall {
                    VStack(spacing: 4) { ForEach(0..<cards, id: \.self) { _ in card } }.padding(6)
                } else {
                    HStack(spacing: 4) { ForEach(0..<cards, id: \.self) { _ in card } }.padding(6)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}
