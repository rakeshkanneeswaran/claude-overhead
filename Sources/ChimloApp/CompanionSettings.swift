import AppKit
import ChimloCore
import SwiftUI

/// Settings panes come from Core (`SettingsPaneID`): seven, one place for
/// each kind of choice. GitHub's pane is the integration only.
typealias SettingsPane = SettingsPaneID

extension SettingsPaneID {
    var title: String { displayName }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .notifications: "bell.badge"
        case .usage: "gauge.with.dots.needle.33percent"
        case .shortcuts: "command"
        case .github: "point.3.connected.trianglepath.dotted"
        case .privacy: "hand.raised"
        }
    }
}

/// Settings: the pane the sidebar chose, under its name and a search field.
/// The panes are listed in the sidebar (`SettingsSidebar`), which takes the
/// workspace list's place while Settings is open.
struct CompanionSettingsView: View {
    @ObservedObject var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var highlighted = 0

    private var query: String { navigation.settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: [SettingsEntry] { SettingsCatalog.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(query.isEmpty ? navigation.settingsPane.title : "Search")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                SettingsSearchField(
                    text: $navigation.settingsSearch,
                    isFocused: $searchFocused,
                    onSubmit: openHighlighted,
                    onMove: moveHighlight
                )
                .frame(width: 230)
            }
            .frame(maxWidth: SettingsMetrics.contentWidth)
            .padding(.horizontal, SettingsMetrics.pagePadding)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 14)

            Group {
                if query.isEmpty {
                    SettingsPaneView(pane: navigation.settingsPane)
                        .id(navigation.settingsPane)
                        .transition(.opacity)
                } else {
                    SettingsSearchResults(query: query, results: results, highlighted: highlighted) { entry in
                        navigation.showSettings(at: entry.anchor)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: navigation.settingsPane)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: query.isEmpty)
        }
        // ⌘F puts the cursor in the search field.
        .background(
            Button("Search settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .onChange(of: navigation.settingsSearch) { _, _ in highlighted = 0 }
    }

    private func openHighlighted() {
        let found = results
        guard found.indices.contains(highlighted) else { return }
        navigation.showSettings(at: found[highlighted].anchor)
    }

    private func moveHighlight(_ step: Int) {
        let count = results.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + step, 0), count - 1)
    }
}

private struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .notifications: NotificationsPane()
        case .usage: ContextUsagePane()
        case .shortcuts: ShortcutsPane()
        case .github: GitHubIntegrationView()
        case .privacy: PrivacyPane()
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var services: OverheadServices
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var settings: SettingsModel
    @State private var confirmReset = false

    private var listenerText: String {
        switch model.serverState {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case let .listening(port): "Listening on 127.0.0.1:\(port) only"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build"
    }

    var body: some View {
        SettingsPage {
            SettingsSection(.startup, "Startup") {
                SettingsGroup {
                    Toggle("Open Claude Overhead at login", isOn: settings.binding(\.launchAtLogin))
                }
                if let problem = services.loginItemProblem { SettingsNote(problem) }
            }

            SettingsSection(.display, "Display") {
                SettingsGroup {
                    SettingsRow("Show the notch on") {
                        Picker("Show the notch on", selection: settings.binding(\.preferredDisplay)) {
                            Text("The display with a notch").tag(DisplayPreference.notchedDisplay)
                            Text("The main display").tag(DisplayPreference.mainDisplay)
                            Text("The display with the pointer").tag(DisplayPreference.displayWithPointer)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SettingsSection(
                .behaviour,
                "Behaviour",
                info: "Hide outside the notch: for fullscreen video and the like. The closed notch draws nothing beside the camera, no character, activity or glow, and opens only when you click the notch. The eye button in the open notch does the same. Sessions are still watched, and a permission request or question still shows, because Claude is waiting for it.\n\nLock Mode: while locked, the notch never opens by itself. Every session is still watched, the sounds you turned on still play, and a permission request or question waits in the notch, never approved or dropped, until you click the notch to answer it.\n\nUnattended runs: a run started by a script (claude -p) has nobody at a Claude Code prompt, so Claude Code decides by itself and the run carries on. Off, Claude Overhead stays out of those runs. On, their permission requests and questions wait in the notch, and the run stops until you answer or the request expires."
            ) {
                SettingsGroup {
                    SettingsToggle(
                        "Lock Mode",
                        detail: "The notch opens only when you click it. Requests wait, never approved or dropped.",
                        isOn: settings.binding(\.notchLocked)
                    )
                    SettingsToggle(
                        "Hide outside the notch",
                        detail: "Nothing shows beside the camera until you click the notch. Requests still show.",
                        isOn: settings.binding(\.notchHidden)
                    )
                    SettingsToggle(
                        "Ask me about unattended runs",
                        detail: "Requests from scripted runs (claude -p) wait in the notch for you.",
                        isOn: settings.binding(\.askAboutUnattendedRuns)
                    )
                }
            }

            SettingsSection(
                .claudeCode,
                "Claude Code",
                info: "Claude Overhead adds hooks to ~/.claude/settings.json only after you confirm, keeps a backup, and removes only its own entries when you disconnect."
            ) {
                SettingsGroup {
                    ClaudeConnectionRow()
                    SettingsRow("Local listener") {
                        Text(listenerText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow("Setup", detail: "Walk through connecting Claude Code again.") {
                        Button("Run Setup Again") { model.presentSetup?(true) }
                    }
                }
            }

            SettingsSection(.updates, "Updates") {
                SettingsGroup {
                    UpdateStatusRow(model: model)
                    if let installed = model.installedReleaseNotes {
                        SettingsRow("What's New") {
                            Button(installed.menuTitle) { model.showWhatsNewForInstalledVersion() }
                        }
                    }
                    if model.updatePresentation?.failure?.suggestsInstallCommand == true {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Or update from Terminal; it keeps your settings:")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            HStack(alignment: .top) {
                                Text(AppUpdateFailure.installCommand)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(AppUpdateFailure.installCommand, forType: .string)
                                }
                            }
                        }
                    }
                }
            }

            SettingsSection(.about, "About") {
                SettingsGroup {
                    SettingsRow("Version") {
                        Text(version).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    SettingsRow("Licence") {
                        Text("GPL-3.0").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text("Claude Overhead is a fork of Chimlo by Kartike Bansal, used under the GPL-3.0. It is not made by or affiliated with Anthropic.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsRow("Quit") {
                        Button("Quit Claude Overhead") { NSApp.terminate(nil) }
                    }
                }
            }

            SettingsSection(.reset, "Reset") {
                SettingsGroup {
                    SettingsRow(
                        "Reset all settings",
                        detail: "History, the Claude Code connection and your Keychain token are kept."
                    ) {
                        Button("Reset…") { confirmReset = true }
                    }
                }
            }
        }
        .confirmationDialog("Reset every Overhead setting?", isPresented: $confirmReset) {
            Button("Reset settings", role: .destructive) { settings.settings = OverheadSettings() }
        } message: {
            Text("History, the Claude Code connection and your Keychain token are kept.")
        }
    }
}

// MARK: - Appearance

/// How the notch and this window look: the notch's layout, the characters,
/// the completion glow, the colour theme, what the notch shows, and motion.
/// It is meant to be understood by looking, so each choice is drawn.
private struct AppearancePane: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var model: ApplicationModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.overheadPalette) private var palette

    private var layout: NotchLayout { settings.settings.layout }

    var body: some View {
        SettingsPage {
            SettingsJumpBar(anchors: [
                (.layout, "Layout"), (.characters, "Characters"), (.glow, "Completion glow"), (.theme, "Theme"),
                (.notchContent, "In the notch"), (.lists, "Sessions"), (.accessibility, "Accessibility"),
            ])
            SettingsSection(.layout, "Notch layout") {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                        ForEach(NotchLayout.allCases) { candidate in
                            Button { settings.settings.layout = candidate } label: {
                                LayoutCard(layout: candidate, selected: layout == candidate)
                            }
                            .buttonStyle(.plain)
                            .help(candidate.summary)
                            .accessibilityLabel("\(candidate.displayName) layout")
                            .accessibilityHint(candidate.summary)
                            .accessibilityAddTraits(layout == candidate ? .isSelected : [])
                        }
                    }
                    HStack(spacing: 6) {
                        Text(layout.summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.textSecondary)
                        Spacer(minLength: 6)
                        let spec = layout.spec
                        if spec.showsActivityLabel { Pill(text: "Activity") }
                        if spec.showsContextIndicator { Pill(text: "Context") }
                        if spec.showsAgentIndicator { Pill(text: "Agents") }
                        if spec.expandedShowsUsage { Pill(text: "Usage") }
                        if !spec.expandsOnHover { Pill(text: "Click to open") }
                    }
                    .padding(.horizontal, 2)
                }
            }

            CharacterSettingsSection()

            CompletionGlowSection()

            SettingsSection(
                .theme,
                "Colour theme",
                info: "Each theme sets this window's light or dark look and keeps text at WCAG AA contrast; Match System follows macOS as it switches. The notch stays dark so it blends with the camera housing."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                        ForEach(ThemeID.allCases) { theme in
                            Button { settings.settings.theme = theme } label: {
                                ThemeSwatch(
                                    theme: theme,
                                    palette: ThemeLibrary.palette(for: theme, systemIsDark: scheme == .dark),
                                    selected: settings.settings.theme == theme
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(theme.displayName) theme")
                            .accessibilityAddTraits(settings.settings.theme == theme ? .isSelected : [])
                        }
                    }
                    SettingsGroup {
                        SettingsRow("Accent colour") {
                            Picker("Accent colour", selection: settings.binding(\.accent)) {
                                ForEach(AccentChoice.allCases) { accent in
                                    HStack {
                                        Circle().fill(accent.color(isDark: true).color).frame(width: 10, height: 10)
                                        Text(accent.displayName)
                                    }
                                    .tag(accent)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            }

            SettingsSection(.notchContent, "In the notch") {
                SettingsGroup {
                    Toggle("Show live activity in the closed notch", isOn: settings.binding(\.showClosedNotchActivity))
                        .disabled(!settings.settings.layout.spec.showsActivityLabel)
                    Toggle("Show subagents", isOn: settings.binding(\.showAgents))
                    SettingsRow("Session rows") {
                        Picker("Session rows", selection: settings.binding(\.density)) {
                            Text("Comfortable (branch, context and agents)").tag(RowDensity.comfortable)
                            Text("Compact").tag(RowDensity.compact)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SettingsSection(.lists, "Sessions and Overview") {
                SettingsGroup {
                    SettingsRow("Sort sessions by") {
                        Picker("Sort sessions by", selection: settings.binding(\.sessionSort)) {
                            Text("Needs you first").tag(SessionSort.attentionFirst)
                            Text("Recent activity").tag(SessionSort.recentActivity)
                            Text("Project").tag(SessionSort.project)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Toggle("Group sessions by project", isOn: settings.binding(\.groupByProject))
                    Toggle("Show today's recap on Overview", isOn: settings.binding(\.dailyRecapEnabled))
                }
            }

            SettingsSection(
                .accessibility,
                "Accessibility",
                info: "Reduce Motion and Increase Contrast are macOS settings. Claude Overhead follows them as they change, and Reduce Motion always wins over the animation setting here."
            ) {
                SettingsGroup {
                    SettingsRow("Animation") {
                        Picker("Animation", selection: settings.binding(\.animationIntensity)) {
                            Text("Full").tag(AnimationIntensity.full)
                            Text("Reduced").tag(AnimationIntensity.reduced)
                            Text("Minimal").tag(AnimationIntensity.minimal)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    SettingsRow("Reduce Motion", detail: "From macOS. The notch and every glow hold still.") {
                        SystemSettingStatus(isOn: model.accessibility.reduceMotion)
                    }
                    SettingsRow("Increase Contrast", detail: "From macOS. Raised surfaces in the notch are stronger.") {
                        SystemSettingStatus(isOn: model.accessibility.increaseContrast)
                    }
                }
            }
        }
    }
}

/// A macOS accessibility setting the app follows: its state, and the way to
/// where it is changed.
private struct SystemSettingStatus: View {
    let isOn: Bool
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Text(isOn ? "On" : "Off")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? palette.success : palette.textSecondary)
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }
}

/// Settings › Appearance: the completion glow's own switch, its themes and
/// its brightness. Nothing here reads or changes a sound setting.
private struct CompletionGlowSection: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var model: ApplicationModel
    @Environment(\.overheadPalette) private var palette
    @State private var hovered: GlowTheme?

    private var isOn: Bool { settings.settings.completionGlowEnabled }
    private var chosen: GlowTheme { settings.settings.completionGlowTheme }

    var body: some View {
        SettingsSection(
            .glow,
            "Completion glow",
            info: "When Claude finishes a turn, the closed notch lights up for a moment and does not open. Choosing a glow plays it on the notch. Sound is a separate choice: a session's bell in the notch decides what you hear, whether the glow is on or off. Turning the glow off keeps your glow for when you turn it back on."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsGroup {
                    Toggle("Glow when Claude finishes a turn", isOn: Binding(
                        get: { isOn },
                        set: { settings.settings.setCompletionGlowEnabled($0) }
                    ))
                }
                if isOn {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: 8)], spacing: 8) {
                        ForEach(GlowTheme.allCases) { theme in
                            Button { choose(theme) } label: {
                                GlowThemeSwatch(
                                    theme: theme,
                                    selected: theme == chosen,
                                    flows: (theme == chosen || theme == hovered) && !model.reducesMotion
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { inside in
                                if inside { hovered = theme } else if hovered == theme { hovered = nil }
                            }
                            .help(theme.summary)
                            .accessibilityLabel("\(theme.displayName) glow")
                            .accessibilityHint(theme.summary)
                            .accessibilityAddTraits(theme == chosen ? .isSelected : [])
                        }
                    }
                    SettingsGroup {
                        SettingsRow("Brightness", detail: "\(chosen.displayName): \(chosen.summary.prefix(1).lowercased() + chosen.summary.dropFirst()).") {
                            HStack(spacing: 10) {
                                SettingsSlider(
                                    value: Binding(
                                        get: { max(settings.settings.glowIntensity, CompletionGlow.brightnessRange.lowerBound) },
                                        set: { settings.settings.glowIntensity = $0 }
                                    ),
                                    range: CompletionGlow.brightnessRange,
                                    label: "Glow brightness",
                                    onRelease: { model.previewCompletionGlow() }
                                )
                                Button("Preview") { model.previewCompletionGlow() }
                                    .accessibilityHint("Shows the chosen glow on the notch.")
                            }
                        }
                    }
                } else {
                    SettingsNote("No glow shows when a turn finishes. Sessions whose bell is on still sound. \(chosen.displayName) is kept for when you turn the glow back on.")
                }
            }
        }
    }

    /// Choosing a theme saves it and plays it once on the real notch.
    private func choose(_ theme: GlowTheme) {
        settings.settings.completionGlowTheme = theme
        model.previewCompletionGlow()
    }
}

struct ClaudeConnectionRow: View {
    @EnvironmentObject private var model: ApplicationModel

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code").font(.system(size: 13))
                Text(model.claudeConnectionText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            action
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.claudeConnectionState {
        case .checking: ProgressView().controlSize(.small).frame(width: 16)
        case .disconnected: Image(systemName: "circle").foregroundStyle(.secondary)
        case .installedAwaitingEvent, .receiving: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsRepair: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .unavailable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch model.claudeConnectionState {
        case .checking: EmptyView()
        case .disconnected: Button("Connect", action: model.connectClaude)
        case .needsRepair: Button("Repair", action: model.connectClaude)
        case .installedAwaitingEvent, .receiving: Button("Disconnect", action: model.disconnectClaude)
        case .unavailable: Button("Retry", action: model.refreshAgentConnections)
        }
    }
}

// MARK: - Layouts

/// One layout to choose: a drawing of the closed notch as that layout shows
/// it, and its name.
private struct LayoutCard: View {
    let layout: NotchLayout
    let selected: Bool
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            NotchPreview(spec: layout.spec)
            Text(layout.displayName)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)
        }
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity)
        .background(selected ? palette.accentColor.opacity(0.1) : palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? palette.accentColor : palette.hairlineColor, lineWidth: selected ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accentColor)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Where updates stand, in one row: up to date, an update on offer (its
/// button opens What's New, where the update is started), busy, or failed
/// with a way to try again.
struct UpdateStatusRow: View {
    @ObservedObject var model: ApplicationModel

    private var summary: UpdateStatusSummary {
        UpdateStatusSummary(
            phase: model.updatePresentation?.phase,
            installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    var body: some View {
        let summary = summary
        HStack(alignment: .center, spacing: 12) {
            icon(for: summary.tone)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.system(size: 13, weight: .medium))
                Text(summary.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(model.updatePresentation?.actionTitle ?? "Check for Updates") {
                if model.updatePresentation?.isAvailable == true || model.updatePresentation?.failure != nil {
                    model.installUpdate()
                } else {
                    model.checkForUpdates()
                }
            }
            .disabled(model.updatePresentation.map { !$0.isActionable } ?? false)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func icon(for tone: UpdateStatusSummary.Tone) -> some View {
        switch tone {
        case .busy:
            ProgressView().controlSize(.small)
        case .neutral:
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 16)).foregroundStyle(.secondary)
        case .good:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(ChimloTheme.liveGreen)
        case .offer:
            Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(ChimloTheme.providerOrange)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(ChimloTheme.clayText)
        }
    }
}

/// The closed notch as a layout shows it: how wide its wings are, whether
/// the session's mark or a still dot sits on the left, which signals sit on
/// the right, and whether a line of live activity hangs under the camera.
private struct NotchPreview: View {
    let spec: NotchLayoutSpec
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        let wing = 20 * spec.compactWingWidthScale
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [palette.raisedColor, palette.raisedColor.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ZStack {
                        if spec.showsAvatar {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(ChimloTheme.providerOrange)
                                .frame(width: 10, height: 9)
                        } else {
                            Circle().fill(ChimloTheme.providerOrange).frame(width: 4.5, height: 4.5)
                        }
                    }
                    .frame(width: wing)
                    Color.black.frame(width: 56)
                    HStack(spacing: 2) {
                        if spec.showsActivityLabel { Image(systemName: "terminal").font(.system(size: 6.5, weight: .semibold)) }
                        if spec.showsContextIndicator { ContextRing(fraction: 0.62, health: .healthy, size: 7) }
                        if spec.showsAgentIndicator { AgentDots(count: 2, maximum: 2) }
                        if !spec.showsActivityLabel, !spec.showsContextIndicator, !spec.showsAgentIndicator {
                            Circle().fill(ChimloTheme.providerOrange.opacity(0.9)).frame(width: 3.5, height: 3.5)
                        }
                    }
                    .foregroundStyle(ChimloTheme.providerOrange)
                    .frame(width: wing)
                }
                .frame(height: 19)
                if spec.showsActivityLabel {
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 48, height: 2.5)
                        .padding(.top, 1)
                        .padding(.bottom, 5)
                }
            }
            .background(Color.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7, style: .continuous))
        }
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Themes

private struct ThemeSwatch: View {
    let theme: ThemeID
    let palette: ThemePalette
    let selected: Bool
    @Environment(\.overheadPalette) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach([palette.working, palette.waiting, palette.success, palette.failure], id: \.self) { color in
                    Circle().fill(color.color).frame(width: 10, height: 10)
                }
            }
            Text(theme.displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.textPrimary.color)
                .lineLimit(1)
            RoundedRectangle(cornerRadius: 3).fill(palette.raised.color).frame(height: 12)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background.color)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(selected ? app.accentColor : palette.hairline.color, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(app.accentColor)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Notifications & Sound

private struct NotificationsPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var services: OverheadServices
    @EnvironmentObject private var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette

    private func kinds(_ priority: NotificationPriority) -> [OverheadEventKind] {
        OverheadEventKind.allCases.filter { $0.priority == priority && !$0.isGitHub }
    }

    var body: some View {
        SettingsPage {
            SettingsJumpBar(anchors: [
                (.sound, "Sound"), (.completionSound, "Completion"), (.claudeEvents, "Claude"), (.githubEvents, "GitHub"), (.delivery, "Banners"),
                (.quietHours, "Quiet hours"), (.focus, "Focus mode"),
            ])
            SettingsSection(
                .sound,
                "Sound",
                info: "Every Claude session starts silent. Click a session's bell in the notch to hear it when it finishes, fails or needs you; other sessions stay quiet. The volume applies on top of your Mac's own."
            ) {
                SettingsGroup {
                    Toggle("Play sounds", isOn: settings.binding(\.notifications.soundsEnabled))
                    SettingsRow("Alert sound", detail: "Permission requests, questions and failures.") {
                        HStack(spacing: 8) {
                            Picker("Alert sound", selection: settings.binding(\.notifications.soundChoice)) {
                                ForEach(NotificationSoundChoice.allCases) { choice in
                                    Text(choice.displayName).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button("Preview") { preview() }
                                .accessibilityHint("Plays the chosen sound at the chosen volume.")
                        }
                    }
                    SettingsRow("Volume") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                            Slider(
                                value: settings.binding(\.notifications.soundVolume),
                                in: NotificationSoundVolume.range,
                                onEditingChanged: { editing in if !editing { preview() } }
                            )
                            .frame(width: 200)
                            .accessibilityLabel("Sound volume")
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                SettingsNote("Sessions start silent. A session's bell in the notch turns its sound on.")
            }

            SettingsSection(
                .completionSound,
                "Completion sound",
                info: "What a finished turn plays, for a session whose bell is on. Until you choose one, it is the alert sound, as before. Press a sound's play button to hear it; click the sound to choose it. The volume above applies to every sound, and the completion glow is set on its own in Appearance."
            ) {
                CompletionSoundPicker(
                    selected: settings.settings.notifications.completionSound,
                    alertName: settings.settings.notifications.soundChoice.displayName,
                    choose: { id in
                        settings.settings.notifications.completionSound = id
                        previewCompletion(id)
                    },
                    preview: previewCompletion
                )
            }

            SettingsSection(
                .claudeEvents,
                "Claude notifications",
                info: "Critical events (permission requests, questions, failures) always appear in the notch and can never be hidden. Ambient events only ever show in the notch."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    eventGroup("Claude is blocked", kinds(.critical))
                    eventGroup("Informational", kinds(.informational))
                    eventGroup("In the notch only", kinds(.ambient))
                }
            }

            SettingsSection(
                .githubEvents,
                "GitHub notifications",
                info: "Each repository's own alert level is set in Settings → GitHub. Quiet hours, Focus and the sound switch apply to GitHub events too."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    eventGroup("GitHub", OverheadEventKind.allCases.filter(\.isGitHub))
                    SettingsGroup {
                        SettingsToggle(
                            "Group related notifications",
                            detail: "Several notices of one kind from one repository arrive as one.",
                            isOn: settings.binding(\.github.groupNotifications)
                        )
                    }
                }
            }

            SettingsSection(
                .delivery,
                "Banners",
                info: "Claude Overhead asks macOS for banner permission only when you allow banners here."
            ) {
                SettingsGroup {
                    SettingsRow("macOS banners") {
                        switch services.bannerAuthorization {
                        case .allowed: Text("Allowed").font(.system(size: 12)).foregroundStyle(.secondary)
                        case .denied:
                            Text("Turned off in System Settings → Notifications")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        case .notDetermined: Button("Allow banners…") { services.requestBannerAuthorization() }
                        }
                    }
                    Toggle("Group completion banners", isOn: settings.binding(\.notifications.groupCompletions))
                }
            }

            SettingsSection(
                .quietHours,
                "Quiet hours",
                info: "During quiet hours informational banners and sounds stop; critical events still show in the notch."
            ) {
                SettingsGroup {
                    Toggle("Quiet hours", isOn: settings.binding(\.notifications.quietHoursEnabled))
                    if settings.settings.notifications.quietHoursEnabled {
                        DailyWindowEditor(window: Binding(
                            get: { settings.settings.notifications.quietHours ?? .defaultQuietHours },
                            set: { settings.settings.notifications.quietHours = $0 }
                        )).rows
                    }
                }
            }

            SettingsSection(
                .focus,
                "Focus mode",
                info: "Focus keeps the notch calm while you concentrate (the moon in the notch, or ⌃⌥F). Permission requests and questions still show, because Claude cannot continue without you."
            ) {
                SettingsGroup {
                    Toggle("Focus mode", isOn: settings.binding(\.focus.isOn))
                    Toggle("Hide informational notifications", isOn: settings.binding(\.focus.suppressInformational))
                    Toggle("Mute sounds", isOn: settings.binding(\.focus.muteSounds))
                    Toggle("Reduce animations", isOn: settings.binding(\.focus.reduceAnimations))
                    Toggle("Hide activity labels", isOn: settings.binding(\.focus.hideActivityLabels))
                    Toggle("Turn Focus on automatically", isOn: settings.binding(\.focus.scheduleEnabled))
                    if settings.settings.focus.scheduleEnabled {
                        DailyWindowEditor(window: Binding(
                            get: { settings.settings.focus.schedule ?? DailyWindow(startMinutes: 9 * 60, endMinutes: 12 * 60, weekdaysOnly: true) },
                            set: { settings.settings.focus.schedule = $0 }
                        )).rows
                    }
                }
            }
        }
        .onAppear { services.refreshBannerAuthorization() }
    }

    /// One table of events: each event's name, then whether it shows, sounds
    /// and posts a banner, under one row of column names.
    private func eventGroup(_ title: String, _ kinds: [OverheadEventKind]) -> some View {
        SettingsGroup {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 8)
                ForEach(["Show", "Sound", "Banner"], id: \.self) { column in
                    Text(column)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                        .frame(width: EventPreferenceRow.columnWidth)
                }
            }
            .accessibilityHidden(true)
            for kind in kinds {
                EventPreferenceRow(kind: kind)
            }
        }
    }

    private func previewCompletion(_ id: String) {
        services.model.previewCompletionSound(
            id,
            alert: settings.settings.notifications.soundChoice,
            volume: settings.settings.notifications.soundVolume
        )
    }

    private func preview() {
        services.model.previewSound(
            settings.settings.notifications.soundChoice,
            volume: settings.settings.notifications.soundVolume
        )
    }
}

struct EventPreferenceRow: View {
    let kind: OverheadEventKind
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette

    static let columnWidth: CGFloat = 58

    var body: some View {
        let preference = settings.settings.notifications.preference(for: kind)
        HStack(spacing: 0) {
            Text(kind.displayName)
                .font(.system(size: 13))
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 8)
            Group {
                if kind.blocksClaude {
                    Text("Always")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                        .help("Always shown: Claude cannot continue until you answer.")
                } else {
                    checkbox("Show \(kind.displayName)", \.enabled, preference)
                }
            }
            .frame(width: Self.columnWidth)
            Group {
                if kind.priority != .ambient { checkbox("Sound for \(kind.displayName)", \.sound, preference) }
            }
            .frame(width: Self.columnWidth)
            Group {
                if kind.priority != .ambient { checkbox("Banner for \(kind.displayName)", \.systemBanner, preference) }
            }
            .frame(width: Self.columnWidth)
        }
    }

    private func checkbox(
        _ label: String,
        _ keyPath: WritableKeyPath<EventPreference, Bool>,
        _ current: EventPreference
    ) -> some View {
        Toggle(label, isOn: binding(keyPath, current: current))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(label)
    }

    private func binding(_ keyPath: WritableKeyPath<EventPreference, Bool>, current: EventPreference) -> Binding<Bool> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { value in
                var updated = settings.settings.notifications.preference(for: kind)
                updated[keyPath: keyPath] = value
                settings.settings.notifications.perEvent[kind] = updated
            }
        )
    }
}

/// A daily window's start, end and weekdays switch, as rows of a group.
@MainActor
private struct DailyWindowEditor {
    @Binding var window: DailyWindow

    init(window: Binding<DailyWindow>) {
        _window = window
    }

    var rows: [AnyView] {
        [
            AnyView(SettingsRow("From") {
                DatePicker("From", selection: minutes(\.startMinutes), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            }),
            AnyView(SettingsRow("Until") {
                DatePicker("Until", selection: minutes(\.endMinutes), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            }),
            AnyView(Toggle("Weekdays only", isOn: $window.weekdaysOnly)),
        ]
    }

    private func minutes(_ keyPath: WritableKeyPath<DailyWindow, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(window[keyPath: keyPath]) * 60)
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                window[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}

// MARK: - Usage

private struct ContextUsagePane: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        SettingsPage {
            SettingsSection(
                .context,
                "Context window",
                info: "Context is how full one session's conversation is. Claude Code compacts it automatically near the limit."
            ) {
                SettingsGroup {
                    threshold("Warn at", \.contextAttentionThreshold)
                    threshold("Critical at", \.contextCriticalThreshold)
                }
            }
            SettingsSection(
                .limits,
                "5-hour and weekly limits",
                info: "Plan limits are per account. Claude Code reports them through its status line, which runs in the terminal but not in the VS Code extension."
            ) {
                SettingsGroup {
                    threshold("Warn at", \.usageWarningThreshold)
                    Toggle("Show reset countdowns", isOn: settings.binding(\.showResetCountdowns))
                }
            }
            SettingsSection(.cache, "Prompt cache") {
                SettingsGroup {
                    Toggle("Show prompt-cache metrics", isOn: settings.binding(\.showCacheMetrics))
                }
            }
        }
    }

    private func threshold(_ label: String, _ keyPath: WritableKeyPath<OverheadSettings, Double>) -> some View {
        SettingsRow(label) {
            SettingsSlider(
                value: settings.binding(keyPath),
                range: OverheadSettings.thresholdRange,
                step: 0.05,
                label: label
            )
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var services: OverheadServices
    @Environment(\.overheadPalette) private var palette
    @State private var recording: ShortcutAction?
    @State private var problem: String?

    private var isEnabled: Bool { settings.settings.shortcutsEnabled }

    var body: some View {
        SettingsPage {
            SettingsSection(
                .shortcuts,
                "Global shortcuts",
                info: "Shortcuts use macOS's hot-key service, so they need no Accessibility permission. A shortcut another app already owns is marked unavailable.",
                accessory: {
                    Button("Restore Defaults") { settings.settings.shortcuts = ShortcutDefaults.bindings }
                        .controlSize(.small)
                        .disabled(!isEnabled)
                }
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsGroup {
                        Toggle("Global shortcuts", isOn: settings.binding(\.shortcutsEnabled))
                    }
                    SettingsGroup {
                        for action in ShortcutAction.allCases {
                            HStack(spacing: 10) {
                                Text(action.displayName).font(.system(size: 13))
                                if services.unavailableShortcuts.contains(action), isEnabled {
                                    Label("In use by another app", systemImage: "exclamationmark.triangle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(palette.warning)
                                }
                                Spacer(minLength: 8)
                                ShortcutRecorder(
                                    combo: settings.settings.shortcuts[action],
                                    isRecording: recording == action,
                                    start: { recording = action; problem = nil },
                                    finish: { combo in record(combo, for: action) },
                                    clear: { settings.settings.shortcuts[action] = nil }
                                )
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1 : 0.55)
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.warning)
                            .padding(.horizontal, 2)
                    } else {
                        SettingsNote("Click a shortcut, then press the new keys. Esc cancels.")
                    }
                }
            }
        }
    }

    private func record(_ combo: KeyCombo?, for action: ShortcutAction) {
        recording = nil
        guard let combo else { return }
        let conflicts = ShortcutValidator.conflicts(for: combo, action: action, in: settings.settings.shortcuts)
        guard conflicts.isEmpty else {
            problem = conflicts.map { conflict in
                switch conflict {
                case let .duplicate(other): "\(combo.displayString) is already used for “\(other.displayName)”."
                case let .reservedBySystem(feature): "\(combo.displayString) is used by macOS for \(feature)."
                case .needsModifier: "Use ⌘, ⌃ or ⌥ so the shortcut does not fire while typing."
                }
            }.joined(separator: " ")
            return
        }
        settings.settings.shortcuts[action] = combo
    }
}

/// Click, then press a key combination. Uses a local key monitor, which sees
/// keys only while this window is focused and needs no permission.
private struct ShortcutRecorder: View {
    let combo: KeyCombo?
    let isRecording: Bool
    let start: () -> Void
    let finish: (KeyCombo?) -> Void
    let clear: () -> Void
    @State private var monitor: Any?
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop(nil) : begin()
            } label: {
                Group {
                    if isRecording {
                        Text("Press keys…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.accentColor)
                    } else if let combo {
                        KeyCaps(combo: combo)
                    } else {
                        Text("Not set")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .frame(minWidth: 96, minHeight: 26, alignment: .trailing)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? palette.accentColor : Color.clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the new shortcut, or Esc to cancel" : "Click to record a new shortcut")
            .accessibilityLabel(isRecording ? "Recording. Press the new shortcut" : (combo?.displayString ?? "Not set"))
            .accessibilityHint("Records a new shortcut")
            Button { clear() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(palette.textTertiary)
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove shortcut")
                .help("Remove this shortcut")
                .opacity(combo != nil && !isRecording ? 1 : 0)
                .disabled(combo == nil || isRecording)
        }
        .onDisappear { removeMonitor() }
        // Another row started recording, so this one stopped without a key
        // press: its monitor must go, or it swallows the next key typed
        // anywhere in the app and may save it as this row's shortcut.
        .onChange(of: isRecording) { _, recording in
            if !recording { removeMonitor() }
        }
    }

    private func begin() {
        start()
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop(nil)
                return nil
            }
            var modifiers: KeyModifiers = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            stop(KeyCombo(keyCode: event.keyCode, modifiers: modifiers))
            return nil
        }
    }

    private func stop(_ combo: KeyCombo?) {
        removeMonitor()
        finish(combo)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var history: HistoryModel
    @Environment(\.overheadPalette) private var palette
    @State private var confirmClear = false
    @State private var note: String?

    var body: some View {
        SettingsPage {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(palette.success)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your data stays on this Mac.")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text("No telemetry and no analytics. Nothing about your sessions is sent anywhere.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(palette.success.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
            .accessibilityElement(children: .combine)

            SettingsSection(
                .history,
                "History",
                info: "History is a summary per session: status, project, branch, files, agents, tests, pull requests and reported cost. Claude Code's own transcripts are never copied or changed."
            ) {
                SettingsGroup {
                    Toggle("Keep your last prompt and Claude's last reply in history", isOn: settings.binding(\.storeConversationPreviews))
                    SettingsRow("Keep history for") {
                        Picker("Keep history for", selection: settings.binding(\.historyRetentionDays)) {
                            Text("7 days").tag(Int?.some(7))
                            Text("30 days").tag(Int?.some(30))
                            Text("90 days").tag(Int?.some(90))
                            Text("1 year").tag(Int?.some(365))
                            Text("Forever").tag(Int?.none)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SettingsSection(.yourData, "Your data") {
                SettingsGroup {
                    SettingsRow("Sessions kept") {
                        Text("\(history.records.count)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow("History file") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([history.store.fileURL])
                        }
                    }
                    SettingsRow("Export", detail: "Save every session summary as a JSON file.") {
                        Button("Export History…") { export() }
                    }
                    SettingsRow("Delete", detail: "Removes Claude Overhead's summaries. Claude Code's transcripts are not touched.") {
                        Button("Delete All History…", role: .destructive) { confirmClear = true }
                    }
                }
                if let note { SettingsNote(note) }
            }

            SettingsSection(.network, "Network and permissions") {
                SettingsGroup {
                    SettingsDetails("What stays on this Mac") {
                        Text("Your sessions, history and settings, and a GitHub token if you save one (in the Keychain). Claude Code talks to Claude Overhead through hooks on this Mac only (127.0.0.1). Claude Code's own transcripts are never copied or changed.")
                    }
                    SettingsDetails("GitHub, only when you turn it on") {
                        Text("Requests go to api.github.com for the repositories you selected: pull requests, reviews, checks and Actions runs. The only thing written is a merge you confirm. Logs are never downloaded.")
                    }
                    SettingsDetails("Update checks") {
                        Text("Every hour, and when you click Check for Updates, the app reads its signed update feed from the latest release on github.com. The pictures in a release's What's New come from that release too. An update is downloaded only when you click Update Now.")
                    }
                    SettingsDetails("Claude Code's usage check") {
                        Text("Plan limits come from Claude Code itself, which reports them on this Mac. When they are stale, Claude Overhead can start Claude Code for a moment and run /usage; that request is Claude Code's own. No tokens, Keychain items or cookies are read.")
                    }
                    SettingsDetails("macOS permissions") {
                        Text("No Accessibility and no Screen Recording. macOS asks before Claude Overhead controls Terminal or iTerm (to show a session's tab), posts banners, or reads project folders in Documents, Desktop, Downloads or iCloud Drive.")
                    }
                }
            }
        }
        .confirmationDialog("Delete all of Overhead's history?", isPresented: $confirmClear) {
            Button("Delete history", role: .destructive) {
                history.clearAll()
                note = "History deleted. Claude Code's transcripts were not touched."
            }
        } message: {
            Text("This removes Overhead's session summaries. It does not touch Claude Code's own transcripts.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "overhead-history.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await history.export(to: url)
                note = "Exported to \(url.lastPathComponent)."
            } catch {
                note = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
