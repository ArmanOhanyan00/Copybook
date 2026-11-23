import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The panel: a prominent search field, a timeline of clips grouped by day, cards that
// understand their content, and an action bar for what's selected. Liquid Glass controls
// float over the glass panel; cards are soft, tinted by their source app, with spring motion.

enum PanelStyle {
    /// Corner radius of the panel itself.
    static let panelRadius: CGFloat = 32
    static let label = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let cardBackground = Color.dynamic(light: 0xFFFFFF, dark: 0x1F1F22)
    static let cardSunken = Color.dynamic(light: 0xF2F2F5, dark: 0x2A2A2E)
    static let hairline = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
    static let pill = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.13)
    static let accent = Color.accentColor

    static let card = CGSize(width: 228, height: 232)
    static let cardRadius: CGFloat = 22
    static let innerRadius: CGFloat = 14     // concentric: card radius minus the 8 pt inset
    static let cardSpacing: CGFloat = 14
    static let actionBarHeight: CGFloat = 46
    /// The strip along the top edge that moves the panel. The controls sit below it, so the
    /// grab area is clearly separate from the search field and buttons.
    static let gripStrip: CGFloat = 20
    /// Extra space above the top row of controls (the grab strip plus a little air).
    static let topInset: CGFloat = 14
    /// Space between a day label and its cards (the selection ring reaches 5 pt beyond a card).
    static let dayLabelGap: CGFloat = 13
    /// Extra space above a day label that starts a new group in the vertical list.
    static let groupTopPadding: CGFloat = 10
    /// The most a card may grow in the horizontal layout, however tall the panel is.
    static let maxCardHeight: CGFloat = 300
    /// The vertical layout stacks the summary above full-width labelled buttons.
    static func actionBarHeight(vertical: Bool) -> CGFloat { vertical ? 86 : actionBarHeight }
    /// Vertical layout: side padding and card heights.
    static let verticalInset: CGFloat = 16
    static let verticalCardHeight: CGFloat = 148
    static let verticalImageHeight: CGFloat = 208
    static func verticalHeight(for kind: ClipKind) -> CGFloat { kind == .image ? verticalImageHeight : verticalCardHeight }
    /// List format: one compact row per clip.
    static let listRowHeight: CGFloat = 56
    static let listRowSpacing: CGFloat = 8
    static let listMaxWidth: CGFloat = 720
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let quick = Animation.spring(response: 0.24, dampingFraction: 0.86)
}

// MARK: - Glass helpers (Liquid Glass on macOS 26+, material elsewhere)

extension View {
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: Capsule())
        } else {
            self.background(Capsule().fill(.regularMaterial))
        }
    }

    @ViewBuilder
    func glassID(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) { self.glassEffectID(id, in: ns) } else { self }
    }

    /// The main action button: Liquid Glass prominent on macOS 26+, bordered prominent before.
    @ViewBuilder
    func modernProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent).controlSize(.regular)
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Root

struct PanelRoot: View {
    @ObservedObject var store: Store
    @ObservedObject var model: PanelModel
    @ObservedObject var prefs: Prefs
    let core: AppCore

    var body: some View {
        let items = core.visibleItems()
        VStack(spacing: 0) {
            TopBar(store: store, model: model, prefs: prefs, core: core, count: items.count)
                .frame(height: 60)
                .padding(.horizontal, 16)
                .padding(.top, PanelStyle.topInset)
            ZStack {
                if items.isEmpty {
                    EmptyStateView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    CardStrip(items: items, store: store, model: model, core: core)
                        .id(model.listToken)   // a fresh list each time the panel opens: back at the top
                        .transition(.opacity)
                }
            }
            ActionBar(store: store, model: model, core: core)
                .frame(height: PanelStyle.actionBarHeight(vertical: model.vertical))
        }
        .environment(\.cardSize, model.cardSize)
        .environment(\.verticalCards, model.sideMedia)
        .modifier(PromptBlur(active: model.placementPrompt))
        // Keep the blur inside the panel's rounded shape instead of spilling into its corners.
        .clipShape(RoundedRectangle(cornerRadius: PanelStyle.panelRadius, style: .circular))
        .overlay { PlacementHandles(core: core) }
        .overlay {
            if model.placementPrompt {
                PlacementPrompt(core: core).transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(PanelStyle.spring, value: model.placementPrompt)
        .overlay(alignment: .bottom) {
            if model.showAccessNotice {
                AccessNotice { withAnimation(PanelStyle.spring) { model.showAccessNotice = false } }
                    .padding(.bottom, PanelStyle.actionBarHeight(vertical: model.vertical) + 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(PanelStyle.spring, value: model.showAccessNotice)
        .onChange(of: model.query) { _, _ in core.resetCursorToFirst() }
        .onChange(of: model.typeFilter) { _, _ in core.resetCursorToFirst() }
        .onChange(of: model.appFilter) { _, _ in core.resetCursorToFirst() }
    }
}

/// Shown (never a system prompt) when a double-click can't paste because
/// Accessibility is off: the clip was copied instead.
struct AccessNotice: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Copied. Press ⌘V to paste, or allow Copybook in Accessibility to paste with a double-click.")
                .font(.system(size: 12.5))
                .foregroundStyle(PanelStyle.label)
            Button("Open Settings") { Paster.requestTrustFromUser(); dismiss() }
                .buttonStyle(.capsule)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(PanelStyle.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.regularMaterial))
        .glassCapsule()
    }
}

struct EmptyStateView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(PanelStyle.tertiary)
                .symbolEffect(.bounce, value: model.revealed)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(PanelStyle.secondary)
            Text(subtitle).font(.system(size: 12.5)).foregroundStyle(PanelStyle.tertiary)
        }
        .opacity(model.revealed ? 1 : 0)
        .offset(y: model.revealed ? 0 : 8)
        .animation(PanelStyle.spring, value: model.revealed)
    }

    private var filtering: Bool { !model.query.isEmpty || model.typeFilter != nil || model.appFilter != nil }

    private var symbol: String {
        if filtering { return "magnifyingglass" }
        return "list.clipboard"
    }
    private var title: String {
        if filtering { return "Nothing found" }
        return "History is empty"
    }
    private var subtitle: String {
        if filtering { return "Try another word or clear the filter." }
        return "Copy something to get started."
    }
}

// MARK: - Top bar: search on the left, title and menu on the right

struct TopBar: View {
    @ObservedObject var store: Store
    @ObservedObject var model: PanelModel
    @ObservedObject var prefs: Prefs
    let core: AppCore
    let count: Int
    @ObservedObject private var stack: StackController
    @FocusState private var searchFocused: Bool

    init(store: Store, model: PanelModel, prefs: Prefs, core: AppCore, count: Int) {
        self.store = store
        self.model = model
        self.prefs = prefs
        self.core = core
        self.count = count
        _stack = ObservedObject(wrappedValue: core.stack)
    }

    private var filtering: Bool { !model.query.isEmpty || model.typeFilter != nil || model.appFilter != nil }

    var body: some View {
        HStack(spacing: 10) {
            search
            if prefs.isPaused {
                Group {
                    if model.vertical {
                        Image(systemName: "pause.fill").frame(width: 38, height: 38).glassCapsule()
                    } else {
                        Label("Paused", systemImage: "pause.fill").padding(.horizontal, 12).frame(height: 32).glassCapsule()
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .help("Capturing is paused")
            }
            if !model.vertical {
                Spacer(minLength: 12)
                ClipboardTitle()
                    .layoutPriority(1)
            }
            if stack.isActive {
                GlassIconButton(symbol: "square.stack.3d.up.fill", label: "Stack is open", tint: PanelStyle.accent) {
                    core.stack.toggle()
                }
            }
            GlassIconButton(symbol: "eyedropper", label: pickLabel) { core.pickColor() }
            GlassIconButton(symbol: "rectangle.landscape.rotate",
                            label: model.vertical ? "Switch to the horizontal layout" : "Switch to the vertical layout") {
                core.toggleLayout()
            }
            GlassIconButton(symbol: model.pinned ? "pin.fill" : "pin",
                            label: model.pinned ? "Unpin" : "Pin in place",
                            tint: model.pinned ? PanelStyle.accent : PanelStyle.label) {
                core.panelController.setPinned(!model.pinned)
            }
            moreMenu
        }
        .onReceive(model.$focusToken) { _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    /// Always-visible search; typing anywhere in the panel lands here.
    private var search: some View {
        HStack(spacing: 8) {
            Button {
                model.searchOpen = true
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(searchFocused || filtering ? PanelStyle.label : PanelStyle.secondary)
                    .frame(width: 18, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
            filterMenu
            if filtering {
                Button {
                    withAnimation(PanelStyle.spring) {
                        model.query = ""; model.typeFilter = nil; model.appFilter = nil; model.searchOpen = false
                    }
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(PanelStyle.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(minWidth: model.vertical ? 110 : 210, idealWidth: 360, maxWidth: model.vertical ? .infinity : 360)
        .frame(height: 38)
        .glassCapsule(interactive: true)
        .animation(PanelStyle.quick, value: filtering)
        .help("Search by text, app or type. Just start typing.")
    }

    private var pickLabel: String {
        "Pick a colour from the screen" + (prefs.pickColorShortcut.map { " (\($0.display))" } ?? "")
    }

    private var placeholder: String {
        if model.vertical { return "Search" }   // the field is narrow here; a longer hint would be cut off
        return count > 0 ? "Search \(count.formatted()) clips" : "Search"
    }

    private var filterMenu: some View {
        Menu {
            Section("Type") {
                ForEach(ClipKind.allCases) { kind in
                    Toggle(isOn: Binding(get: { model.typeFilter == kind }, set: { model.typeFilter = $0 ? kind : nil })) {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                }
            }
            Section("App") {
                ForEach(store.sourceApps.prefix(25), id: \.id) { app in
                    Toggle(app.name, isOn: Binding(get: { model.appFilter == app.id },
                                                   set: { model.appFilter = $0 ? app.id : nil }))
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let kind = model.typeFilter {
                    Image(systemName: kind.symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(model.typeFilter?.label ?? (model.appFilter.flatMap { AppInfo.name(for: $0) } ?? "All"))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(model.typeFilter != nil || model.appFilter != nil ? PanelStyle.accent : PanelStyle.secondary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(PanelStyle.pill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter")
    }

    private var moreMenu: some View {
        Menu {
            Button("New Text Item") { core.newTextItem() }
            Button(stack.isActive ? "Close Stack" : "Open Stack") { core.stack.toggle() }
            Button("Pick Colour") { core.pickColor() }
            Button(model.vertical ? "Use Horizontal Layout" : "Use Vertical Layout") { core.toggleLayout() }
            Divider()
            if prefs.isPaused {
                Button("Resume Capturing") { core.resume() }
            } else {
                Menu("Pause Capturing") {
                    Button("For 15 Minutes") { core.pause(minutes: 15) }
                    Button("For 1 Hour") { core.pause(minutes: 60) }
                    Button("For 8 Hours") { core.pause(minutes: 480) }
                    Button("Until Resumed") { core.pause(minutes: 0) }
                }
            }
            Button("Erase History…") { core.confirmEraseHistory(fromPanel: true) }
            Divider()
            Button("Settings…") { core.openSettings() }
            Button("Quit Copybook") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PanelStyle.label)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassCapsule(interactive: true)
        .help("More")
        .accessibilityLabel("More")
    }
}

/// A round Liquid Glass button for a single symbol.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var tint: Color = PanelStyle.label
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Title chip

/// The panel's title: just "Clipboard", in a glass capsule.
struct ClipboardTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
            Text("Clipboard").lineLimit(1)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(PanelStyle.label)
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(Capsule().fill(PanelStyle.cardBackground).shadow(color: .black.opacity(0.1), radius: 3, y: 1))
        .padding(4)
        .glassCapsule()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clipboard")
    }
}

// MARK: - Timeline of cards, grouped by day

struct CardStrip: View {
    let items: [ClipItem]
    @ObservedObject var store: Store
    @ObservedObject var model: PanelModel
    let core: AppCore

    static let leading: CGFloat = 20
    /// Distance from the panel's bottom edge to the bottom of the cards (used by the self-test).
    static let bottomPadding: CGFloat = 10
    static let bottom: CGFloat = PanelStyle.actionBarHeight + bottomPadding

    /// One card in the row; the first card of each day carries that day's label.
    private struct Entry: Identifiable {
        let index: Int
        let item: ClipItem
        let groupTitle: String?
        let groupCount: Int
        var id: UUID { item.id }
    }

    private var entries: [Entry] {
        let cal = Calendar.current
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return "This Week" }
            return "Earlier"
        }
        let titles = items.map { bucket($0.date) }
        var counts: [String: Int] = [:]
        for t in titles { counts[t, default: 0] += 1 }
        return items.indices.map { i in
            let starts = i == 0 || titles[i] != titles[i - 1]
            return Entry(index: i, item: items[i], groupTitle: starts ? titles[i] : nil, groupCount: counts[titles[i]] ?? 0)
        }
    }

    private static let labelHeight: CGFloat = 16

    var body: some View {
        if model.cardFormat == .list { listBody }
        else if model.vertical { verticalBody }
        else { horizontalBody }
    }

    private func dayLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(PanelStyle.label)
            Text("\(count)")
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PanelStyle.tertiary)
        }
        .padding(.leading, 6)
        .fixedSize()
        .opacity(model.revealed ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: model.revealed)
    }

    private var horizontalBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: PanelStyle.cardSpacing) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: PanelStyle.dayLabelGap) {
                            Group {
                                if let title = entry.groupTitle {
                                    dayLabel(title, count: entry.groupCount)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: model.cardSize.width, height: Self.labelHeight, alignment: .leading)
                            CardView(item: entry.item, index: entry.index, store: store, model: model, core: core)
                                .contextMenu { CardMenu(item: entry.item, store: store, core: core) }
                        }
                        // A little extra air where a new day begins.
                        .padding(.leading, entry.groupTitle != nil && entry.index > 0 ? 14 : 0)
                        .id(entry.item.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
                .padding(.horizontal, Self.leading)
                .padding(.top, 2)
                .padding(.bottom, Self.bottomPadding)
            }
            .scrollClipDisabled()
            .onChange(of: model.cursorID) { _, id in
                guard let id else { return }
                withAnimation(PanelStyle.spring) { proxy.scrollTo(id) }
            }
        }
    }

    /// One row of cards in the vertical panel. A day's first row carries its label.
    private struct CardRow: Identifiable {
        let entries: [Entry]
        var id: UUID { entries[0].item.id }
        var groupTitle: String? { entries[0].groupTitle }
        var groupCount: Int { entries[0].groupCount }
    }

    /// The cards in rows of `columns`; a new day always starts a new row.
    private func rows(columns: Int) -> [CardRow] {
        var out: [[Entry]] = []
        for e in entries {
            if let last = out.last, e.groupTitle == nil, last.count < columns { out[out.count - 1].append(e) } else { out.append([e]) }
        }
        return out.map { CardRow(entries: $0) }
    }

    /// Vertical layout: cards side by side wherever there is room for more than one, day labels between the groups.
    private var verticalBody: some View {
        let columns = max(1, model.columns)
        let rows = rows(columns: columns)
        let rowOf = Dictionary(uniqueKeysWithValues: rows.flatMap { r in r.entries.map { ($0.item.id, r.id) } })
        let width = model.cardSize.width * CGFloat(columns) + CardStyle.columnGap * CGFloat(columns - 1)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .center, spacing: PanelStyle.cardSpacing) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: PanelStyle.dayLabelGap) {
                            if let title = row.groupTitle {
                                dayLabel(title, count: row.groupCount)
                                    .frame(height: Self.labelHeight)
                            }
                            HStack(alignment: .top, spacing: CardStyle.columnGap) {
                                ForEach(row.entries) { entry in
                                    CardView(item: entry.item, index: entry.index, store: store, model: model, core: core)
                                        .contextMenu { CardMenu(item: entry.item, store: store, core: core) }
                                }
                            }
                        }
                        // The cards fill the width of the panel; a shape narrower than it sits in the middle,
                        // with its day label above its left edge.
                        .frame(width: width, alignment: .leading)
                        .padding(.top, row.groupTitle != nil && row.entries[0].index > 0 ? PanelStyle.groupTopPadding : 0)
                        .id(row.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }
                }
                .padding(.horizontal, PanelStyle.verticalInset)
                .frame(maxWidth: .infinity)
            }
            // Safe-area padding (not content padding), so scrolling a card into view keeps it
            // clear of the soft fades at the top and bottom.
            .safeAreaPadding(.top, 14)
            .safeAreaPadding(.bottom, 22)
            // Cards scroll under the search bar and the action bar: fade them out softly
            // at both ends instead of cutting them off with a hard edge.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                }
            }
            .onChange(of: model.cursorID) { _, id in
                guard let id, let row = rowOf[id] else { return }
                withAnimation(PanelStyle.spring) { proxy.scrollTo(row) }
            }
        }
    }

    /// List format: compact rows. A tall panel has one column; a wide bar fits several side by side.
    private var listBody: some View {
        let columns = max(1, model.columns)
        let rows = rows(columns: columns)
        let rowOf = Dictionary(uniqueKeysWithValues: rows.flatMap { r in r.entries.map { ($0.item.id, r.id) } })
        let width = model.cardSize.width * CGFloat(columns) + CardStyle.columnGap * CGFloat(columns - 1)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .center, spacing: PanelStyle.listRowSpacing) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: PanelStyle.dayLabelGap - 4) {
                            if let title = row.groupTitle {
                                dayLabel(title, count: row.groupCount)
                                    .frame(height: Self.labelHeight)
                            }
                            HStack(alignment: .top, spacing: CardStyle.columnGap) {
                                ForEach(row.entries) { entry in
                                    ListRow(item: entry.item, index: entry.index, store: store, model: model, core: core)
                                        .frame(width: model.cardSize.width)
                                        .contextMenu { CardMenu(item: entry.item, store: store, core: core) }
                                }
                            }
                        }
                        .frame(width: width, alignment: .leading)
                        .padding(.top, row.groupTitle != nil && row.entries[0].index > 0 ? PanelStyle.groupTopPadding : 0)
                        .id(row.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .padding(.horizontal, model.vertical ? PanelStyle.verticalInset : CardStrip.leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaPadding(.top, 14)
            .safeAreaPadding(.bottom, 22)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                }
            }
            .onChange(of: model.cursorID) { _, id in
                guard let id, let row = rowOf[id] else { return }
                withAnimation(PanelStyle.spring) { proxy.scrollTo(row) }
            }
        }
    }
}

// MARK: - List rows

/// One clip as a compact row: a thumbnail or icon, what it says, where it came from, and when.
struct ListRow: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var store: Store
    @ObservedObject var model: PanelModel
    let core: AppCore
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var selected: Bool { model.selectedIDs.contains(item.id) }
    private var flash: PanelModel.Flash? { model.flash?.id == item.id ? model.flash : nil }
    private static let radius: CGFloat = 16
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }
    private static let thumb: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                title
                HStack(spacing: 5) {
                    if let icon = AppInfo.icon(for: item.sourceBundleID) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 13, height: 13)
                    }
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(PanelStyle.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            preview
            if model.commandHeld && index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PanelStyle.label)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(PanelStyle.pill))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            Text(RelativeTime.short(item.date, now: model.openedAt))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(PanelStyle.secondary)
        }
        .padding(.leading, 18).padding(.trailing, 9)
        .frame(height: PanelStyle.listRowHeight)
        .background(PanelStyle.cardBackground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius + 4, style: .continuous)
                .strokeBorder(PanelStyle.accent, lineWidth: 2.5)
                .padding(-4)
                .opacity(selected ? 1 : 0)
                .scaleEffect(selected ? 1 : 0.98)
        }
        .overlay { if let flash { FlashBadge(flash: flash).transition(.scale(scale: 0.8).combined(with: .opacity)) } }
        .overlay { CardInteraction(item: item, core: core) { hovering = $0 } }
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.06), radius: hovering ? 12 : 7, y: hovering ? 5 : 3)
        .contentShape(shape)
        .animation(PanelStyle.quick, value: hovering)
        .animation(PanelStyle.quick, value: selected)
        .animation(PanelStyle.quick, value: model.commandHeld)
        .animation(PanelStyle.spring, value: flash?.token)
        .opacity(model.revealed ? 1 : 0)
        .offset(y: model.revealed ? 0 : 10)
        .animation(PanelStyle.spring.delay(Double(min(index, 10)) * 0.02), value: model.revealed)
    }

    // The row's headline, or a field while it is being renamed.
    @ViewBuilder
    private var title: some View {
        if model.renamingItemID == item.id {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .focused($focused)
                .onSubmit { core.commitRename(item.id, draft) }
                .onAppear {
                    draft = item.title ?? ""
                    DispatchQueue.main.async { focused = true }
                }
        } else {
            Text(headline)
                .font(item.kind == .color ? .system(size: 13.5, weight: .semibold, design: .monospaced) : .system(size: 13.5, weight: .semibold))
                .foregroundStyle(PanelStyle.label)
                .lineLimit(1)
                .truncationMode(item.kind == .file ? .middle : .tail)
        }
    }

    private var headline: String {
        if let t = item.title, !t.isEmpty { return t }
        switch item.kind {
        case .text:
            let first = TextShape.split(item.text ?? "").title
            return first.isEmpty ? "Empty text" : first
        case .link: return item.linkTitle?.isEmpty == false ? item.linkTitle! : (item.linkURL?.host ?? item.text ?? "Link")
        case .image: return "Image"
        case .color: return item.text ?? "Colour"
        case .file:
            let paths = item.filePaths ?? []
            return paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
        }
    }

    /// The app it came from, and one fact about the clip.
    private var detail: String {
        let app = item.sourceAppName ?? "Unknown app"
        switch item.kind {
        case .text:
            let words = item.text?.split(whereSeparator: \.isWhitespace).count ?? 0
            return "\(app) · \(words.formatted()) word\(words == 1 ? "" : "s")"
        case .link: return "\(app) · \(item.linkURL?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link")"
        case .image:
            if let w = item.imageWidth, let h = item.imageHeight { return "\(app) · \(w) × \(h)" }
            return app
        case .color: return "\(app) · Colour"
        case .file:
            let n = item.filePaths?.count ?? 0
            return n > 1 ? "\(app) · \(n) files" : app
        }
    }

    /// A real picture of what was copied (an image, a colour, a link's picture, a file's icon), small, at the
    /// right edge. Plain text gets nothing: the words are the row.
    @ViewBuilder
    private var preview: some View {
        let box = RoundedRectangle(cornerRadius: 10, style: .continuous)
        switch item.kind {
        case .image:
            if let img = store.displayImage(item) { picture(img, box) }
        case .link:
            if let img = store.linkImage(item) { picture(img, box) }
        case .color:
            let ns = (ColorParser.parse(item.text ?? "") ?? .gray).usingColorSpace(.sRGB) ?? .gray
            Color(nsColor: ns)
                .frame(width: Self.thumb, height: Self.thumb)
                .clipShape(box)
                .overlay(box.strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
        case .file:
            if let path = item.filePaths?.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable().interpolation(.high)
                    .frame(width: Self.thumb - 4, height: Self.thumb - 4)
            }
        case .text:
            EmptyView()
        }
    }

    private func picture(_ image: NSImage, _ box: RoundedRectangle) -> some View {
        PanelStyle.cardSunken
            .overlay { Image(nsImage: image).resizable().interpolation(.high).antialiased(true).aspectRatio(contentMode: .fill) }
            .frame(width: Self.thumb, height: Self.thumb)
            .clipShape(box)
            .overlay(box.strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
    }
}

// MARK: - Cards

struct CardView: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var store: Store
    @ObservedObject var model: PanelModel
    let core: AppCore
    @State private var hovering = false
    @Environment(\.cardSize) private var size
    @Environment(\.verticalCards) private var vertical

    static var size: CGSize { PanelStyle.card }

    /// A chosen shape: every card is the same size. Automatic: the same in the horizontal layout; in the
    /// vertical one, wide rows that are taller for pictures.
    private var cardHeight: CGFloat { model.automaticCards && model.vertical ? PanelStyle.verticalHeight(for: item.kind) : size.height }

    private var selected: Bool { model.selectedIDs.contains(item.id) }
    private var flash: PanelModel.Flash? { model.flash?.id == item.id ? model.flash : nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: PanelStyle.cardRadius, style: .continuous) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(item: item, model: model, core: core)
            CardContent(item: item, store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            CardFooter(item: item, index: index, showShortcut: model.commandHeld && index < 9)
        }
        .environment(\.cardSize, CGSize(width: size.width, height: cardHeight))
        .frame(width: size.width, height: cardHeight)
        .background(PanelStyle.cardBackground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
        .overlay {
            RoundedRectangle(cornerRadius: PanelStyle.cardRadius + 5, style: .continuous)
                .strokeBorder(PanelStyle.accent, lineWidth: 2.5)
                .padding(-5)
                .opacity(selected ? 1 : 0)
                .scaleEffect(selected ? 1 : 0.97)
        }
        .overlay { if let flash { FlashBadge(flash: flash).transition(.scale(scale: 0.8).combined(with: .opacity)) } }
        // Native clicks and drags (real clip data, rounded drag preview).
        .overlay { CardInteraction(item: item, core: core) { hovering = $0 } }
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.08), radius: hovering ? 20 : 12, y: hovering ? 10 : 5)
        .scaleEffect(hovering ? 1.02 : 1)
        .contentShape(shape)
        .animation(PanelStyle.quick, value: hovering)
        .animation(PanelStyle.quick, value: selected)
        .animation(PanelStyle.spring, value: flash?.token)
        .opacity(model.revealed ? 1 : 0)
        .offset(y: model.revealed ? 0 : 16)
        .animation(PanelStyle.spring.delay(Double(min(index, 10)) * 0.02), value: model.revealed)
    }
}

/// Glass capsule confirming a copy.
struct FlashBadge: View {
    let flash: PanelModel.Flash

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .symbolEffect(.bounce, value: flash.token)
            Text(flash.message)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(PanelStyle.label)
        .padding(.horizontal, 14).frame(height: 32)
        .background(Capsule().fill(.regularMaterial))
        .glassCapsule()
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

/// App icon, app (or custom) name and time.
struct CardHeader: View {
    let item: ClipItem
    @ObservedObject var model: PanelModel
    let core: AppCore
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = AppInfo.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: item.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PanelStyle.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(PanelStyle.pill))
                }
            }
            .frame(width: 22, height: 22)
            if model.renamingItemID == item.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .focused($focused)
                    .onSubmit { core.commitRename(item.id, draft) }
                    .onAppear {
                        draft = item.title ?? ""
                        DispatchQueue.main.async { focused = true }
                    }
            } else {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PanelStyle.label)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(RelativeTime.short(item.date, now: model.openedAt))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(PanelStyle.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .help(item.sourceAppName ?? "")
    }

    private var name: String {
        if let t = item.title, !t.isEmpty { return t }
        return item.sourceAppName ?? item.kind.label
    }
}

/// Reads a text clip: is it code, a short note, or prose with a first line worth leading with?
enum TextShape {
    static func isCode(_ s: String) -> Bool {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let signals = [";", "{", "}", "=>", "->", "func ", "let ", "const ", "def ", "import ", "</", "():", "()", "return "]
        let hits = signals.filter { s.contains($0) }.count
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        return (lines.count >= 2 && hits >= 2) || indented >= 2 || hits >= 4
    }

    /// First meaningful line as a title, the rest as body.
    static func split(_ s: String) -> (title: String, body: String) {
        let lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }) else { return ("", "") }
        let rest = lines[(first + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (lines[first], rest)
    }
}

/// The content of a card, presented according to what it is.
struct CardContent: View {
    let item: ClipItem
    @ObservedObject var store: Store
    @Environment(\.cardSize) private var size
    @Environment(\.verticalCards) private var vertical

    /// Vertical layout: media sits beside the text instead of above it.
    private static let sideMedia: CGFloat = 92

    var body: some View {
        switch item.kind {
        case .text: text
        case .link: link
        case .image: image
        case .color: color
        case .file: file
        }
    }

    private var fadeMask: LinearGradient {
        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: vertical ? 0.86 : 0.72),
                               .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var text: some View {
        let raw = item.text ?? ""
        if TextShape.isCode(raw) {
            // Code sits in its own inset block, in monospace.
            Text(String(raw.prefix(700)))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PanelStyle.label.opacity(0.85))
                .lineSpacing(2)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(fadeMask)
                .background(RoundedRectangle(cornerRadius: PanelStyle.innerRadius, style: .continuous).fill(PanelStyle.cardSunken))
                .padding(.horizontal, 8)
        } else if let rich = store.richPreview(item) {
            Text(AttributedString(rich))
                .foregroundStyle(PanelStyle.label)
                .lineSpacing(2.5)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(fadeMask)
        } else {
            let parts = TextShape.split(raw)
            if parts.body.isEmpty && parts.title.count <= 140 {
                // A short note reads best large.
                Text(parts.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PanelStyle.label)
                    .lineSpacing(2)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    // A long single paragraph reads as body text; otherwise its first line leads.
                    Text(parts.title)
                        .font(.system(size: parts.body.isEmpty ? 13.5 : 14, weight: parts.body.isEmpty ? .regular : .semibold))
                        .foregroundStyle(PanelStyle.label)
                        .lineSpacing(parts.body.isEmpty ? 2.5 : 0)
                        .lineLimit(parts.body.isEmpty ? 40 : 2)
                    if !parts.body.isEmpty {
                        Text(String(parts.body.prefix(700)))
                            .font(.system(size: 12.5))
                            .foregroundStyle(PanelStyle.secondary)
                            .lineSpacing(2.5)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(fadeMask)
            }
        }
    }

    @ViewBuilder
    private var link: some View {
        let media = InsetMedia(horizontalPadding: vertical ? 0 : 8) {
            if let img = store.linkImage(item) {
                Image(nsImage: img).resizable().interpolation(.high).antialiased(true).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "safari")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(PanelStyle.tertiary)
            }
        }
        if vertical {
            HStack(spacing: 12) {
                media.frame(width: Self.sideMedia).frame(maxHeight: .infinity)
                linkText(lines: 3)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8).padding(.trailing, 14)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                media.frame(height: (size.height * 0.45).rounded())
                linkText(lines: 2).padding(.horizontal, 14)
            }
        }
    }

    private func linkText(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
                Text(item.linkTitle?.isEmpty == false ? item.linkTitle! : (item.linkURL?.host ?? "Link"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PanelStyle.label)
                    .lineLimit(lines)
                Label(item.linkURL?.host?.replacingOccurrences(of: "www.", with: "") ?? "", systemImage: "globe")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PanelStyle.secondary)
                    .lineLimit(1)
        }
    }

    private var image: some View {
        InsetMedia(checkerboard: true) {
            if let img = store.displayImage(item) {
                Image(nsImage: img).resizable().interpolation(.high).antialiased(true).aspectRatio(contentMode: .fill)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let w = item.imageWidth, let h = item.imageHeight {
                Text("\(w) × \(h)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(.leading, 16).padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var color: some View {
        let ns = (ColorParser.parse(item.text ?? "") ?? .gray).usingColorSpace(.sRGB) ?? .gray
        let swatch = InsetMedia(checkerboard: true, horizontalPadding: vertical ? 0 : 8) { Color(nsColor: ns) }
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(ns.hexString)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(PanelStyle.label)
            Text("RGB \(Int(ns.redComponent * 255)) · \(Int(ns.greenComponent * 255)) · \(Int(ns.blueComponent * 255))")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PanelStyle.secondary)
        }
        if vertical {
            HStack(spacing: 12) {
                swatch.frame(width: Self.sideMedia).frame(maxHeight: .infinity)
                text
                Spacer(minLength: 0)
            }
            .padding(.leading, 8).padding(.trailing, 14)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                swatch.frame(height: (size.height * 0.4).rounded())
                text.padding(.horizontal, 14)
            }
        }
    }

    @ViewBuilder
    private var file: some View {
        let paths = item.filePaths ?? []
        let media = InsetMedia(horizontalPadding: vertical ? 0 : 8) {
            if paths.count == 1, let thumb = store.displayImage(item) {
                Image(nsImage: thumb).resizable().interpolation(.high).antialiased(true).aspectRatio(contentMode: .fit).padding(8)
            } else {
                ZStack {
                    ForEach(Array(paths.prefix(3).enumerated().reversed()), id: \.offset) { i, path in
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable().frame(width: vertical ? 48 : 64, height: vertical ? 48 : 64)
                            .offset(x: CGFloat(i) * 10, y: CGFloat(i) * -6)
                    }
                }
            }
        }
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(PanelStyle.label)
                .lineLimit(vertical ? 2 : 1)
                .truncationMode(.middle)
            Text(kindDescription(paths))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(PanelStyle.secondary)
                .lineLimit(1)
        }
        if vertical {
            HStack(spacing: 12) {
                media.frame(width: Self.sideMedia).frame(maxHeight: .infinity)
                text
                Spacer(minLength: 0)
            }
            .padding(.leading, 8).padding(.trailing, 14)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                media.frame(height: (size.height * 0.42).rounded())
                text.padding(.horizontal, 14)
            }
        }
    }

    private func kindDescription(_ paths: [String]) -> String {
        guard paths.count == 1 else { return "Multiple files" }
        let url = URL(fileURLWithPath: paths[0])
        return (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? "File"
    }
}

/// An inset, concentric rounded frame for media. Content is an overlay on a flexible box,
/// so it can never push anything else out of place.
struct InsetMedia<Content: View>: View {
    var checkerboard = false
    var horizontalPadding: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        PanelStyle.cardSunken
            .overlay { if checkerboard { Checkerboard() } }
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: PanelStyle.innerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PanelStyle.innerRadius, style: .continuous)
                .strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
            .padding(.horizontal, horizontalPadding)
    }
}

/// Type and size on the left; the quick-paste number while ⌘ is held.
struct CardFooter: View {
    let item: ClipItem
    let index: Int
    let showShortcut: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(info)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 6)
            if showShortcut {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PanelStyle.label)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(PanelStyle.pill))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .foregroundStyle(PanelStyle.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .animation(PanelStyle.quick, value: showShortcut)
    }

    private var info: String {
        switch item.kind {
        case .text:
            let n = item.text?.count ?? 0
            let words = item.text?.split(whereSeparator: \.isWhitespace).count ?? 0
            return "\(words.formatted()) word\(words == 1 ? "" : "s") · \(n.formatted()) chars"
        case .link: return "Link"
        case .image: return "Image"
        case .color: return "Colour"
        case .file:
            let paths = item.filePaths ?? []
            if paths.count == 1 {
                let attrs = try? FileManager.default.attributesOfItem(atPath: paths[0])
                if let size = attrs?[.size] as? Int64, (attrs?[.type] as? FileAttributeType) != .typeDirectory {
                    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                }
                return FileManager.default.fileExists(atPath: paths[0]) ? "Folder" : "Missing"
            }
            return "\(paths.count) files"
        }
    }
}

// MARK: - Action bar: what's selected, and what you can do with it

struct ActionBar: View {
    @ObservedObject var store: Store
    @ObservedObject var model: PanelModel
    let core: AppCore

    var body: some View {
        let selection = core.selection()
        Group {
            if model.vertical {
                verticalBar(selection)
            } else {
                ViewThatFits(in: .horizontal) {
                    row(selection, style: .full)
                    row(selection, style: .noKeys)
                    row(selection, style: .iconsOnly)
                }
                .padding(.horizontal, 18)
            }
        }
        .frame(maxHeight: .infinity)
        .animation(PanelStyle.quick, value: model.selectedIDs)
    }

    /// Horizontal: what's selected on the left, the actions on the right.
    private func row(_ selection: [ClipItem], style: ActionButton.Style) -> some View {
        HStack(spacing: 10) {
            summary(selection)
                .layoutPriority(-1)
            Spacer(minLength: 12)
            if !selection.isEmpty {
                HStack(spacing: 8) { buttons(selection, style: style) }
                    .fixedSize()
            }
        }
    }

    /// Vertical: the summary on top, then full-width buttons that carry their words.
    private func verticalBar(_ selection: [ClipItem]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            summary(selection)
                .frame(height: 20)
            if !selection.isEmpty {
                HStack(spacing: 8) { buttons(selection, style: .wide) }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, PanelStyle.verticalInset)
        .padding(.top, 10).padding(.bottom, 12)
    }

    @ViewBuilder
    private func buttons(_ selection: [ClipItem], style: ActionButton.Style) -> some View {
        ActionButton(title: "Paste", symbol: "arrow.down.doc", keys: "↩", prominent: true, style: style) { core.pasteSelection(plain: false) }
        ActionButton(title: "Copy", symbol: "doc.on.doc", keys: "⌘C", style: style) { core.copySelection() }
        ActionButton(title: "Preview", symbol: "eye", keys: "Space", style: style) { core.togglePreview() }
    }

    /// The app it came from and when: "[icon] Brave Browser · 4:25 PM".
    @ViewBuilder
    private func summary(_ selection: [ClipItem]) -> some View {
        if selection.count > 1 {
            Text("\(selection.count) clips selected")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PanelStyle.label)
        } else if let item = selection.first {
            HStack(spacing: 7) {
                if let icon = AppInfo.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(item.sourceAppName ?? "Unknown app")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PanelStyle.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("· \(item.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PanelStyle.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else {
            Text("Click to copy · double-click to paste · drag anywhere")
                .font(.system(size: 12.5))
                .foregroundStyle(PanelStyle.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

}

/// An action: its icon, its words and (when there's room) its keyboard shortcut.
struct ActionButton: View {
    /// full: icon, words and shortcut. noKeys: icon and words. iconsOnly: icon. wide: icon and
    /// words, stretched to share the width of a row (vertical layout).
    enum Style { case full, noKeys, iconsOnly, wide }
    let title: String
    let symbol: String
    let keys: String
    var prominent = false
    var style: Style = .full
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                if style != .iconsOnly {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                }
                if style == .full {
                    Text(keys)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(prominent ? Color.white.opacity(0.22) : PanelStyle.pill))
                }
            }
            .foregroundStyle(prominent ? Color.white : PanelStyle.label)
            .padding(.leading, style == .full ? 11 : 12).padding(.trailing, style == .full ? 6 : 12)
            .frame(maxWidth: style == .wide ? .infinity : nil)
            .frame(height: style == .wide ? 32 : 28)
            .background(Capsule().fill(prominent ? AnyShapeStyle(PanelStyle.accent.gradient)
                                                 : AnyShapeStyle(PanelStyle.pill.opacity(hovering ? 1.6 : 1))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .help("\(title) (\(keys))")
        .accessibilityLabel(title)
    }
}

/// Subtle press feedback for custom buttons.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(PanelStyle.quick, value: configuration.isPressed)
    }
}

// MARK: - Shared bits

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.primary.opacity(0.05)))
                }
            }
        }
    }
}

struct CardMenu: View {
    let item: ClipItem
    @ObservedObject var store: Store
    let core: AppCore

    var body: some View {
        let targets = core.targets(for: item)
        let many = targets.count > 1
        Button(many ? "Paste \(targets.count) Items" : "Paste") { core.paste(targets) }
        Button("Paste as Plain Text") { core.paste(targets, plain: true) }
        Button("Copy") { core.copyInPlace(targets) }
        Divider()
        Button("Add to Stack") { core.stack.add(targets) }
        if !many {
            Divider()
            Button("Preview") { core.model.select(item.id); core.togglePreview() }
            if item.kind.isTextual { Button("Edit…") { core.edit(item) } }
            Button("Rename") { core.startRename(item) }
            if item.kind == .link { Button("Open Link") { core.open(item) } }
            if item.kind == .file {
                Button("Open") { core.open(item) }
                Button("Reveal in Finder") { core.reveal(item) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { core.delete(targets) }
    }
}


/// Blurs the panel behind the "keep this size?" prompt. A blur fades the content's own edges to
/// transparent, which showed as a grey rim inside the panel; scaling the blurred content up slightly
/// pushes that faded edge outside the panel's rounded shape, where it is clipped away.
struct PromptBlur: ViewModifier {
    let active: Bool
    @State private var size = CGSize(width: 1000, height: 400)

    func body(content: Content) -> some View {
        let pad: CGFloat = 40
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { size = g.size }
                    .onChange(of: g.size) { _, s in size = s }
            })
            .blur(radius: active ? 14 : 0)
            .scaleEffect(x: active ? 1 + pad * 2 / max(size.width, 1) : 1, y: active ? 1 + pad * 2 / max(size.height, 1) : 1)
    }
}
