import AppKit
import ChimloCore
import SwiftUI

// The parts every Settings pane is built from, so the seven panes look and
// behave as one: a page of sections, each a heading over a group of rows.
// Controls are the system's own (switches, menus, sliders); only the layout
// around them is drawn here.

enum SettingsMetrics {
    static let contentWidth: CGFloat = 780
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 26
    static let groupRadius: CGFloat = 10
    static let rowHorizontal: CGFloat = 14
    static let rowVertical: CGFloat = 9
    static let rowMinHeight: CGFloat = 40
}

/// Collects a group's rows one by one, so the group can put a hairline
/// between them. `if` and `for` work as in any view builder.
@resultBuilder
enum SettingsRows {
    static func buildExpression<V: View>(_ view: V) -> [AnyView] { [AnyView(view)] }
    static func buildExpression(_ views: [AnyView]) -> [AnyView] { views }
    static func buildBlock(_ parts: [AnyView]...) -> [AnyView] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [AnyView]?) -> [AnyView] { part ?? [] }
    static func buildEither(first: [AnyView]) -> [AnyView] { first }
    static func buildEither(second: [AnyView]) -> [AnyView] { second }
    static func buildArray(_ parts: [[AnyView]]) -> [AnyView] { parts.flatMap { $0 } }
}

/// One pane's content: its sections in a readable column that scrolls. When
/// search (or another page) asks for a section, the pane scrolls to it.
struct SettingsPage<Content: View>: View {
    @EnvironmentObject private var navigation: CompanionNavigation
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    content()
                }
                .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: navigation.settingsAnchorRequest) { _, _ in scroll(proxy, animated: true) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let anchor = navigation.settingsAnchor else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
        } else {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}

/// The groups of a long pane as a row of links at its top, so none of them
/// has to be found by scrolling: each one scrolls to its group.
struct SettingsJumpBar: View {
    let anchors: [(anchor: SettingsAnchor, title: String)]
    @EnvironmentObject private var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette

    init(anchors: [(SettingsAnchor, String)]) {
        self.anchors = anchors.map { (anchor: $0.0, title: $0.1) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(anchors, id: \.anchor) { item in
                    Button { navigation.showSettings(at: item.anchor) } label: {
                        Text(item.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(palette.surfaceColor)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(palette.hairlineColor, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to \(item.title)")
                }
            }
            .padding(.horizontal, 1)
        }
        .padding(.bottom, -10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On this page")
    }
}

/// A heading and what belongs under it. `info` is the longer explanation,
/// kept behind a small button so the page stays short.
struct SettingsSection<Accessory: View, Content: View>: View {
    let anchor: SettingsAnchor
    let title: String
    var info: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @EnvironmentObject private var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette
    @State private var flashes = false

    init(
        _ anchor: SettingsAnchor,
        _ title: String,
        info: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.anchor = anchor
        self.title = title
        self.info = info
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let info { SettingsInfoButton(text: info, about: title) }
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 2)
            content()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius + 6, style: .continuous)
                .fill(palette.accentColor.opacity(flashes ? 0.13 : 0))
        )
        .padding(-8)
        .id(anchor)
        .onAppear { flashIfAskedFor() }
        .onChange(of: navigation.settingsAnchorRequest) { _, _ in flashIfAskedFor() }
    }

    /// Search landed here: the section is tinted for a moment so the eye
    /// finds it.
    private func flashIfAskedFor() {
        guard navigation.settingsAnchor == anchor, navigation.settingsAnchorIsFresh else { return }
        flashes = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.easeOut(duration: 0.5)) { flashes = false }
        }
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(
        _ anchor: SettingsAnchor,
        _ title: String,
        info: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(anchor, title, info: info, accessory: { EmptyView() }, content: content)
    }
}

/// Rows on one rounded surface with a hairline between them, as a group in
/// System Settings.
struct SettingsGroup: View {
    private let rows: [AnyView]
    @Environment(\.overheadPalette) private var palette

    init(@SettingsRows rows: () -> [AnyView]) {
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(palette.hairlineColor)
                        .frame(height: 1)
                        .padding(.leading, SettingsMetrics.rowHorizontal)
                }
                rows[index]
                    .padding(.horizontal, SettingsMetrics.rowHorizontal)
                    .padding(.vertical, SettingsMetrics.rowVertical)
                    .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowMinHeight, alignment: .leading)
            }
        }
        .toggleStyle(SettingsSwitchStyle())
        .background(palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous)
                .strokeBorder(palette.hairlineColor, lineWidth: 1)
        )
    }
}

/// A label on the left, with one short line under it when it needs one, and
/// its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control
    @Environment(\.overheadPalette) private var palette

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsLabel(title: title, detail: detail)
            Spacer(minLength: 12)
            control()
        }
    }
}

/// A row's words: its name, and a short second line when one helps.
struct SettingsLabel: View {
    let title: String
    var detail: String?
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch row: `Toggle("Name", isOn:)` inside a group draws its name on
/// the left and the system switch on the right.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .font(.system(size: 13))
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
    }
}

/// A switch with a second line under its name.
struct SettingsToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { SettingsLabel(title: title, detail: detail) }
            .accessibilityLabel(title)
    }
}

/// The longer explanation of a section, one click away.
struct SettingsInfoButton: View {
    let text: String
    /// What it explains, for VoiceOver.
    var about: String
    @State private var isShown = false
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("About \(about)")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

/// Technical detail that is useful to have but not to read every time.
struct SettingsDetails<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var isOpen = false
    @Environment(\.overheadPalette) private var palette

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title).font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(palette.textPrimary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                content()
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                    .transition(.opacity)
            }
        }
    }
}

/// A short line of supporting text under a group.
struct SettingsNote: View {
    let text: String
    @Environment(\.overheadPalette) private var palette

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

/// A slider with its value beside it.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var label: String
    var onRelease: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step, onEditingChanged: released)
                } else {
                    Slider(value: $value, in: range, onEditingChanged: released)
                }
            }
            .frame(width: 200)
            .accessibilityLabel(label)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func released(_ editing: Bool) {
        if !editing { onRelease?() }
    }
}

/// A key combination drawn as keys, as macOS shows shortcuts.
struct KeyCaps: View {
    let combo: KeyCombo
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(combo.keyLabels.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, key.count > 1 ? 5 : 0)
                    .background(palette.raisedColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(palette.hairlineColor, lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combo.displayString)
    }
}

extension KeyCombo {
    /// Each key of the combination on its own: the modifiers, then the key.
    var keyLabels: [String] {
        modifiers.symbols.map(String.init) + [String(displayString.dropFirst(modifiers.symbols.count))]
    }
}

/// The search field at the top of Settings.
struct SettingsSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onMove: (Int) -> Void
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(palette.textTertiary)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.downArrow) { onMove(1); return .handled }
                .onKeyPress(.upArrow) { onMove(-1); return .handled }
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
                .accessibilityLabel("Search settings")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isFocused.wrappedValue ? palette.accentColor : palette.hairlineColor, lineWidth: 1)
        )
    }
}

/// What search found: each setting with its pane and one line about it.
struct SettingsSearchResults: View {
    let query: String
    let results: [SettingsEntry]
    let highlighted: Int
    let open: (SettingsEntry) -> Void
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if results.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No settings match “\(query)”")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Try a single word, such as glow, volume, repository or shortcut.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .padding(.top, 6)
                } else {
                    Text(results.count == 1 ? "1 setting" : "\(results.count) settings")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 2)
                    SettingsGroup {
                        for (index, entry) in results.enumerated() {
                            Button { open(entry) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.pane.symbol)
                                        .font(.system(size: 13))
                                        .foregroundStyle(palette.accentColor)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(palette.textPrimary)
                                        Text("\(entry.pane.displayName) · \(entry.summary)")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(palette.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(palette.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, -6)
                            .padding(.vertical, -3)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index == highlighted ? palette.accentColor.opacity(0.14) : Color.clear)
                                    .padding(.horizontal, -8)
                                    .padding(.vertical, -5)
                            )
                            .accessibilityLabel("\(entry.title), in \(entry.pane.displayName). \(entry.summary)")
                        }
                    }
                }
            }
            .frame(maxWidth: SettingsMetrics.contentWidth, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .padding(.top, 6)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
