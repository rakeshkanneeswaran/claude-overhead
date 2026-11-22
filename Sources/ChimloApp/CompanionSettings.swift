import AppKit
import ChimloCore
import SwiftUI

/// Settings panes come from Core (`SettingsPaneID`). GitHub is not among
/// them: it is configured in the GitHub page's Integration section.
typealias SettingsPane = SettingsPaneID

extension SettingsPaneID {
    var title: String {
        switch self {
        case .general: "General"
        case .personalization: "Personalization"
        case .layouts: "Notch Layouts"
        case .themes: "Themes"
        case .sessions: "Sessions"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .contextUsage: "Context & Usage"
        case .focus: "Focus Mode"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy & Data"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .personalization: "paintbrush"
        case .layouts: "rectangle.topthird.inset.filled"
        case .themes: "circle.lefthalf.filled"
        case .sessions: "list.bullet.rectangle"
        case .notifications: "bell.badge"
        case .agents: "point.3.connected.trianglepath.dotted"
        case .contextUsage: "gauge.with.dots.needle.33percent"
        case .focus: "moon"
        case .shortcuts: "command"
        case .privacy: "hand.raised"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct CompanionSettingsView: View {
    @ObservedObject var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $navigation.settingsPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 200)
            .padding(.top, 28)
            Divider()
            SettingsPaneView(pane: navigation.settingsPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane()
            case .personalization: PersonalizationPane()
            case .layouts: LayoutsPane()
            case .themes: ThemesPane()
            case .sessions: SessionsPane()
            case .notifications: NotificationsPane()
            case .agents: AgentsPane()
            case .contextUsage: ContextUsagePane()
            case .focus: FocusPane()
            case .shortcuts: ShortcutsPane()
            case .privacy: PrivacyPane()
            case .advanced: AdvancedPane()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var services: OverheadServices
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Claude Overhead at login", isOn: settings.binding(\.launchAtLogin))
                if let problem = services.loginItemProblem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Show the notch on", selection: settings.binding(\.preferredDisplay)) {
                    Text("The display with a notch").tag(DisplayPreference.notchedDisplay)
                    Text("The main display").tag(DisplayPreference.mainDisplay)
                    Text("The display with the pointer").tag(DisplayPreference.displayWithPointer)
                }
            }
            Section {
                Toggle("Lock the notch", isOn: settings.binding(\.notchLocked))
            } footer: {
                Text("While locked, the notch never opens by itself. Every session is still watched, the sounds you turned on still play, and a permission request or question waits in the notch, never approved or dropped, until you click the notch to answer it.")
            }
            Section("Claude Code") {
                ClaudeConnectionRow()
                Button("Run setup again") { model.presentSetup?(true) }
            }
            Section("Updates") {
                LabeledContent("Status") {
                    Text(model.updatePresentation?.statusText ?? "Not checked yet")
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.updatePresentation?.actionTitle ?? "Check for Updates") {
                    if model.updatePresentation?.isAvailable == true || model.updatePresentation?.failure != nil {
                        model.installUpdate()
                    } else {
                        model.checkForUpdates()
                    }
                }
                .disabled(model.updatePresentation.map { !$0.isActionable } ?? false)
                if model.updatePresentation?.failure?.suggestsInstallCommand == true {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Or update from Terminal; it keeps your settings:")
                            .font(.callout)
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
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build")
                LabeledContent("License", value: "GPL-3.0")
                Text("Claude Overhead is a fork of Chimlo by Kartike Bansal, used under the GPL-3.0. It is not made by or affiliated with Anthropic.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Quit Claude Overhead") { NSApp.terminate(nil) }
            }
        }
    }
}

struct ClaudeConnectionRow: View {
    @EnvironmentObject private var model: ApplicationModel

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code")
                Text(model.claudeConnectionText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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

// MARK: - Personalization

private struct PersonalizationPane: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        Form {
            Section("Accent") {
                Picker("Accent colour", selection: settings.binding(\.accent)) {
                    ForEach(AccentChoice.allCases) { accent in
                        HStack {
                            Circle().fill(accent.color(isDark: true).color).frame(width: 10, height: 10)
                            Text(accent.displayName)
                        }
                        .tag(accent)
                    }
                }
            }
            Section("Appearance") {
                Picker("Companion window", selection: settings.binding(\.appearance)) {
                    Text("Match macOS").tag(AppearancePreference.system)
                    Text("Dark").tag(AppearancePreference.dark)
                    Text("Light").tag(AppearancePreference.light)
                }
                Text("The notch itself stays dark so it blends with the camera housing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Motion") {
                Picker("Animation", selection: settings.binding(\.animationIntensity)) {
                    Text("Full").tag(AnimationIntensity.full)
                    Text("Reduced").tag(AnimationIntensity.reduced)
                    Text("Minimal").tag(AnimationIntensity.minimal)
                }
                LabeledContent("Completion glow") {
                    Slider(value: settings.binding(\.glowIntensity), in: 0...1)
                        .frame(width: 200)
                }
                Text("macOS Reduce Motion always wins over these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Layouts

private struct LayoutsPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notch Layouts").font(.title2.bold())
                Text("Each layout changes what the closed notch shows and how the panel behaves.")
                    .foregroundStyle(.secondary)
                ForEach(NotchLayout.allCases) { layout in
                    Button { settings.settings.layout = layout } label: {
                        LayoutCard(layout: layout, selected: settings.settings.layout == layout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.settings.layout == layout ? .isSelected : [])
                }
                Divider().padding(.vertical, 4)
                Toggle("Show live activity in the closed notch", isOn: settings.binding(\.showClosedNotchActivity))
                    .disabled(!settings.settings.layout.spec.showsActivityLabel)
                Text(closedNotchActivityNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    private var closedNotchActivityNote: String {
        guard settings.settings.layout.spec.showsActivityLabel else {
            return "\(settings.settings.layout.displayName) keeps the closed notch still. Classic, Expanded and Agent View can show live activity."
        }
        return "One line under the camera with what Claude is doing right now, such as Bash · Run tests. Focus mode hides it while Focus is on, if Hide activity labels is set."
    }
}

private struct LayoutCard: View {
    let layout: NotchLayout
    let selected: Bool
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        let spec = layout.spec
        HStack(spacing: 16) {
            NotchPreview(spec: spec).frame(width: 220, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(layout.displayName).font(.headline)
                Text(layout.summary).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if spec.showsActivityLabel { Pill(text: "Activity") }
                    if spec.showsContextIndicator { Pill(text: "Context") }
                    if spec.showsAgentIndicator { Pill(text: "Agents") }
                    if spec.expandedShowsUsage { Pill(text: "Usage") }
                    if !spec.expandsOnHover { Pill(text: "Click to open") }
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accentColor).font(.title2) }
        }
        .padding(14)
        .background(selected ? palette.accentColor.opacity(0.1) : palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? palette.accentColor : palette.hairlineColor, lineWidth: 1))
    }
}

/// A drawing of the closed notch in a layout: the black camera housing in
/// the middle and what each wing would show.
private struct NotchPreview: View {
    let spec: NotchLayoutSpec

    var body: some View {
        let wing = 34 * spec.compactWingWidthScale
        HStack(spacing: 0) {
            ZStack {
                if spec.showsAvatar {
                    RoundedRectangle(cornerRadius: 3).fill(ChimloTheme.providerOrange).frame(width: 14, height: 14)
                } else {
                    Circle().fill(ChimloTheme.providerOrange).frame(width: 6, height: 6)
                }
            }
            .frame(width: wing)
            Color.black.frame(width: 90)
            HStack(spacing: 3) {
                if spec.showsActivityLabel { Image(systemName: "terminal").font(.system(size: 9)) }
                if spec.showsContextIndicator { ContextRing(fraction: 0.62, health: .healthy, size: 10) }
                if spec.showsAgentIndicator { AgentDots(count: 2, maximum: 2) }
            }
            .foregroundStyle(ChimloTheme.providerOrange)
            .frame(width: wing)
        }
        .frame(height: 30)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - Themes

private struct ThemesPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Themes").font(.title2.bold())
                Text("Themes colour the companion window. Every theme keeps text at WCAG AA contrast.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
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
            }
            .padding(24)
        }
    }
}

private struct ThemeSwatch: View {
    let theme: ThemeID
    let palette: ThemePalette
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach([palette.working, palette.waiting, palette.success, palette.failure], id: \.self) { color in
                    Circle().fill(color.color).frame(width: 12, height: 12)
                }
            }
            Text(theme.displayName).font(.headline).foregroundStyle(palette.textPrimary.color)
            Text("Session · Working").font(.caption).foregroundStyle(palette.textSecondary.color)
            RoundedRectangle(cornerRadius: 4).fill(palette.raised.color).frame(height: 18)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background.color)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : palette.hairline.color, lineWidth: selected ? 2 : 1))
    }
}

// MARK: - Sessions

private struct SessionsPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var model: ApplicationModel

    var body: some View {
        Form {
            Section("Order") {
                Picker("Sort sessions by", selection: settings.binding(\.sessionSort)) {
                    Text("Needs you first").tag(SessionSort.attentionFirst)
                    Text("Recent activity").tag(SessionSort.recentActivity)
                    Text("Project").tag(SessionSort.project)
                }
                Toggle("Group by project in the companion window", isOn: settings.binding(\.groupByProject))
            }
            Section {
                Toggle("Show today's recap on Overview", isOn: settings.binding(\.dailyRecapEnabled))
            } footer: {
                Text("Built on this Mac from your session history and, when GitHub is on, today's pull request and CI activity.")
            }
            Section("Notch panel") {
                Picker("Row density", selection: settings.binding(\.density)) {
                    Text("Comfortable (with branch, context and agents)").tag(RowDensity.comfortable)
                    Text("Compact").tag(RowDensity.compact)
                }
                Toggle("Keep the preview session after onboarding", isOn: $model.keepPreviewSession)
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var services: OverheadServices
    @EnvironmentObject private var github: GitHubModel
    @EnvironmentObject private var navigation: CompanionNavigation

    var body: some View {
        Form {
            Section {
                Toggle("Play sounds", isOn: settings.binding(\.notifications.soundsEnabled))
                HStack {
                    Picker("Sound", selection: settings.binding(\.notifications.soundChoice)) {
                        ForEach(NotificationSoundChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    Button("Preview") { preview() }
                        .accessibilityHint("Plays the chosen sound at the chosen volume.")
                }
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(
                            value: settings.binding(\.notifications.soundVolume),
                            in: NotificationSoundVolume.range,
                            onEditingChanged: { editing in if !editing { preview() } }
                        )
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Sound volume")
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Every Claude session starts silent. Click a session's bell in the notch to hear it when it finishes, fails or needs you; other sessions stay quiet. The volume applies on top of your Mac's own.")
            }
            Section {
                Toggle("Group completion banners", isOn: settings.binding(\.notifications.groupCompletions))
                LabeledContent("macOS banners") {
                    switch services.bannerAuthorization {
                    case .allowed: Text("Allowed").foregroundStyle(.secondary)
                    case .denied: Text("Turned off in System Settings → Notifications").foregroundStyle(.secondary)
                    case .notDetermined: Button("Allow banners…") { services.requestBannerAuthorization() }
                    }
                }
            } footer: {
                Text("Critical events (permission, questions, failures) always appear in the notch and can never be hidden. Overhead asks macOS for banner permission only when you allow banners.")
            }
            ForEach(NotificationPriority.allCases.sorted(by: >), id: \.self) { priority in
                Section(priorityTitle(priority)) {
                    ForEach(OverheadEventKind.allCases.filter { $0.priority == priority && !$0.isGitHub }, id: \.self) { kind in
                        EventPreferenceRow(kind: kind)
                    }
                }
            }
            Section("GitHub") {
                HStack {
                    Text("GitHub's notifications, per event and per repository, are set where GitHub lives.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("GitHub → Integration") {
                        github.companionRequest = .tab(.integration)
                        navigation.show(.github)
                    }
                }
            }
            Section {
                Toggle("Quiet hours", isOn: settings.binding(\.notifications.quietHoursEnabled))
                if settings.settings.notifications.quietHoursEnabled {
                    DailyWindowEditor(window: Binding(
                        get: { settings.settings.notifications.quietHours ?? .defaultQuietHours },
                        set: { settings.settings.notifications.quietHours = $0 }
                    ))
                }
            } footer: {
                Text("During quiet hours informational banners and sounds stop; critical events still show in the notch.")
            }
        }
        .onAppear { services.refreshBannerAuthorization() }
    }

    private func preview() {
        services.model.previewSound(
            settings.settings.notifications.soundChoice,
            volume: settings.settings.notifications.soundVolume
        )
    }

    private func priorityTitle(_ priority: NotificationPriority) -> String {
        switch priority {
        case .critical: "Critical · Claude is blocked"
        case .informational: "Informational"
        case .ambient: "Ambient · notch only"
        }
    }
}

struct EventPreferenceRow: View {
    let kind: OverheadEventKind
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        let preference = settings.settings.notifications.preference(for: kind)
        HStack {
            if kind.blocksClaude {
                Text(kind.displayName)
                Spacer()
                Text("Always shown").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(kind.displayName, isOn: binding(\.enabled, current: preference))
                Spacer()
            }
            if kind.priority != .ambient {
                Toggle("Sound", isOn: binding(\.sound, current: preference)).toggleStyle(.checkbox)
                Toggle("Banner", isOn: binding(\.systemBanner, current: preference)).toggleStyle(.checkbox)
            }
        }
        .help(kind.blocksClaude ? "Always shown: Claude cannot continue until you answer." : "")
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

private struct DailyWindowEditor: View {
    @Binding var window: DailyWindow

    var body: some View {
        DatePicker("From", selection: minutes(\.startMinutes), displayedComponents: .hourAndMinute)
        DatePicker("Until", selection: minutes(\.endMinutes), displayedComponents: .hourAndMinute)
        Toggle("Weekdays only", isOn: $window.weekdaysOnly)
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

// MARK: - Agents

private struct AgentsPane: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Show subagents", isOn: settings.binding(\.showAgents))
            } footer: {
                Text("Subagents come from each session's transcript: what Claude asked the agent to do, its type and model, and whether it finished. Their prompts are never stored.")
            }
            Section("Completion") {
                EventPreferenceRow(kind: .agentCompleted)
            }
        }
    }
}

// MARK: - Context & Usage

private struct ContextUsagePane: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                thresholdSlider("Warn at", \.contextAttentionThreshold)
                thresholdSlider("Critical at", \.contextCriticalThreshold)
            } header: {
                Text("Context window")
            } footer: {
                Text("Context is how full one session's conversation is. Claude Code compacts it automatically near the limit.")
            }
            Section {
                thresholdSlider("Warn at", \.usageWarningThreshold)
                Toggle("Show reset countdowns", isOn: settings.binding(\.showResetCountdowns))
            } header: {
                Text("5-hour and weekly limits")
            } footer: {
                Text("Plan limits are per account. Claude Code reports them through its status line, which runs in the terminal but not in the VS Code extension.")
            }
            Section("Prompt cache") {
                Toggle("Show prompt-cache metrics", isOn: settings.binding(\.showCacheMetrics))
            }
        }
    }

    private func thresholdSlider(_ label: String, _ keyPath: WritableKeyPath<OverheadSettings, Double>) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: settings.binding(keyPath), in: OverheadSettings.thresholdRange, step: 0.05)
                    .frame(width: 220)
                Text("\(Int((settings.settings[keyPath: keyPath] * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 40)
            }
        }
    }
}

// MARK: - Focus

private struct FocusPane: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Focus mode", isOn: settings.binding(\.focus.isOn))
            } footer: {
                Text("Focus keeps the notch calm while you concentrate. Permission requests and questions still show, because Claude cannot continue without you.")
            }
            Section("While Focus is on") {
                Toggle("Hide informational notifications", isOn: settings.binding(\.focus.suppressInformational))
                Toggle("Mute sounds", isOn: settings.binding(\.focus.muteSounds))
                Toggle("Reduce animations", isOn: settings.binding(\.focus.reduceAnimations))
                Toggle("Hide activity labels", isOn: settings.binding(\.focus.hideActivityLabels))
            }
            Section("Schedule") {
                Toggle("Turn on automatically", isOn: settings.binding(\.focus.scheduleEnabled))
                if settings.settings.focus.scheduleEnabled {
                    DailyWindowEditor(window: Binding(
                        get: { settings.settings.focus.schedule ?? DailyWindow(startMinutes: 9 * 60, endMinutes: 12 * 60, weekdaysOnly: true) },
                        set: { settings.settings.focus.schedule = $0 }
                    ))
                }
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var services: OverheadServices
    @State private var recording: ShortcutAction?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Global shortcuts", isOn: settings.binding(\.shortcutsEnabled))
            } footer: {
                Text("Shortcuts use macOS's hot-key service, so they need no Accessibility permission. A shortcut another app already owns is marked unavailable.")
            }
            Section("Shortcuts") {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        Text(action.displayName)
                        if services.unavailableShortcuts.contains(action), settings.settings.shortcutsEnabled {
                            Label("In use by another app", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        ShortcutRecorder(
                            combo: settings.settings.shortcuts[action],
                            isRecording: recording == action,
                            start: { recording = action; problem = nil },
                            finish: { combo in record(combo, for: action) },
                            clear: { settings.settings.shortcuts[action] = nil }
                        )
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                Button("Restore defaults") { settings.settings.shortcuts = ShortcutDefaults.bindings }
            }
            .disabled(!settings.settings.shortcutsEnabled)
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

    var body: some View {
        HStack(spacing: 4) {
            Button(isRecording ? "Press keys…" : combo?.displayString ?? "Not set") {
                isRecording ? stop(nil) : begin()
            }
            .frame(minWidth: 110)
            if combo != nil, !isRecording {
                Button { clear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear { removeMonitor() }
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
    @State private var confirmClear = false
    @State private var note: String?

    var body: some View {
        Form {
            Section("What stays on this Mac") {
                Text("Everything. Overhead has no telemetry or analytics and sends nothing about your sessions anywhere. The only network calls are to GitHub, when you turn it on, and Claude Code's own usage check.")
                    .font(.callout)
            }
            Section {
                Toggle("Keep your last prompt and Claude's last reply in history", isOn: settings.binding(\.storeConversationPreviews))
                Picker("Keep history for", selection: settings.binding(\.historyRetentionDays)) {
                    Text("7 days").tag(Int?.some(7))
                    Text("30 days").tag(Int?.some(30))
                    Text("90 days").tag(Int?.some(90))
                    Text("1 year").tag(Int?.some(365))
                    Text("Forever").tag(Int?.none)
                }
            } header: {
                Text("History")
            } footer: {
                Text("History is a summary per session: status, project, branch, files, agents, tests, pull requests and reported cost. Claude Code's own transcripts are never copied or changed.")
            }
            Section("Your data") {
                LabeledContent("Sessions kept", value: "\(history.records.count)")
                Button("Show history file in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([history.store.fileURL])
                }
                Button("Export history…") { export() }
                Button("Delete all history…", role: .destructive) { confirmClear = true }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
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

// MARK: - Advanced

private struct AdvancedPane: View {
    @EnvironmentObject private var model: ApplicationModel
    @EnvironmentObject private var settings: SettingsModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Claude Code integration") {
                ClaudeConnectionRow()
                LabeledContent("Local listener", value: listenerText)
                Text("Overhead adds hooks to ~/.claude/settings.json only after you confirm, keeps a backup, and removes only its own entries when you disconnect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Settings") {
                Button("Reset all settings to defaults…") { confirmReset = true }
            }
        }
        .confirmationDialog("Reset every Overhead setting?", isPresented: $confirmReset) {
            Button("Reset settings", role: .destructive) { settings.settings = OverheadSettings() }
        } message: {
            Text("History, the Claude Code connection and your Keychain token are kept.")
        }
    }

    private var listenerText: String {
        switch model.serverState {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case let .listening(port): "Listening on 127.0.0.1:\(port) only"
        case let .failed(message): "Failed: \(message)"
        }
    }
}
