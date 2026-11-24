import Foundation

/// A recurring time-of-day window, such as quiet hours or a Focus schedule.
public struct DailyWindow: Codable, Equatable, Sendable {
    /// Minutes after midnight, 0..<1440.
    public var startMinutes: Int
    /// Minutes after midnight. An end before the start crosses midnight.
    /// An end equal to the start is an empty window, never "all day", so a
    /// half-configured window cannot silently mute everything.
    public var endMinutes: Int
    /// Only on days the calendar does not treat as weekend. An overnight
    /// window belongs to the day it starts: Friday 22:00 to 07:00 still covers
    /// early Saturday, and Sunday night's window does not exist.
    public var weekdaysOnly: Bool

    public static let minutesPerDay = 24 * 60
    public static let defaultQuietHours = DailyWindow(startMinutes: 22 * 60, endMinutes: 8 * 60)

    public init(startMinutes: Int, endMinutes: Int, weekdaysOnly: Bool = false) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.weekdaysOnly = weekdaysOnly
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let window = normalized()
        guard window.startMinutes != window.endMinutes else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let now = hour * 60 + minute

        let startDay: Date
        if window.startMinutes < window.endMinutes {
            guard now >= window.startMinutes, now < window.endMinutes else { return false }
            startDay = date
        } else if now >= window.startMinutes {
            startDay = date
        } else if now < window.endMinutes {
            startDay = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        } else {
            return false
        }
        return !window.weekdaysOnly || !calendar.isDateInWeekend(startDay)
    }

    /// When the window `date` is inside comes to its end, or nil when `date`
    /// is outside the window.
    public func end(ofWindowContaining date: Date, calendar: Calendar = .current) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let end = normalized().endMinutes
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: end / 60, minute: end % 60, second: 0),
            matchingPolicy: .nextTime
        )
    }

    /// Minutes wrapped into 0..<1440, so a stray value still means a time.
    public func normalized() -> DailyWindow {
        DailyWindow(
            startMinutes: Self.wrap(startMinutes),
            endMinutes: Self.wrap(endMinutes),
            weekdaysOnly: weekdaysOnly
        )
    }

    private static func wrap(_ minutes: Int) -> Int {
        let remainder = minutes % minutesPerDay
        return remainder < 0 ? remainder + minutesPerDay : remainder
    }

    private enum CodingKeys: String, CodingKey {
        case startMinutes, endMinutes, weekdaysOnly
    }

    public init(from decoder: any Decoder) throws {
        let fallback = DailyWindow.defaultQuietHours
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMinutes = container.lenient(Int.self, .startMinutes) ?? fallback.startMinutes
        endMinutes = container.lenient(Int.self, .endMinutes) ?? fallback.endMinutes
        weekdaysOnly = container.lenient(Bool.self, .weekdaysOnly) ?? fallback.weekdaysOnly
    }
}

public enum SessionSort: String, Codable, Sendable, CaseIterable {
    /// Sessions waiting on the user first, then by recent activity.
    case attentionFirst
    case recentActivity
    case project
}

/// Which display the notch lives on (`NotchScreenChoice` applies it).
public enum DisplayPreference: String, Codable, Sendable, CaseIterable {
    /// The built-in display with a notch, falling back to the main display.
    case notchedDisplay
    /// The primary display, the one System Settings calls the main display.
    case mainDisplay
    /// Whichever display the pointer is on; the notch follows it.
    case displayWithPointer
}

/// Overhead's own Focus mode: fewer interruptions and less motion while the
/// user concentrates. Independent of macOS Focus, which the policy also honours.
public struct FocusPreferences: Codable, Equatable, Sendable {
    public var isOn: Bool
    /// Hide informational events entirely, not just silence them.
    public var suppressInformational: Bool
    /// Silence critical events too. They still show and expand.
    public var muteSounds: Bool
    public var reduceAnimations: Bool
    public var hideActivityLabels: Bool
    public var schedule: DailyWindow?
    public var scheduleEnabled: Bool
    /// The schedule is skipped until this moment: the owner turned Focus off
    /// during a scheduled window, which holds for the rest of that window.
    public var schedulePausedUntil: Date?

    public init(
        isOn: Bool = false,
        suppressInformational: Bool = false,
        muteSounds: Bool = true,
        reduceAnimations: Bool = true,
        hideActivityLabels: Bool = true,
        schedule: DailyWindow? = nil,
        scheduleEnabled: Bool = false,
        schedulePausedUntil: Date? = nil
    ) {
        self.schedulePausedUntil = schedulePausedUntil
        self.isOn = isOn
        self.suppressInformational = suppressInformational
        self.muteSounds = muteSounds
        self.reduceAnimations = reduceAnimations
        self.hideActivityLabels = hideActivityLabels
        self.schedule = schedule
        self.scheduleEnabled = scheduleEnabled
    }

    /// On manually, or inside an enabled schedule the owner has not paused.
    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        if isOn { return true }
        guard scheduleEnabled, let schedule else { return false }
        if let schedulePausedUntil, date < schedulePausedUntil { return false }
        return schedule.contains(date, calendar: calendar)
    }

    /// The notch's Focus button and its shortcut. Off always turns Focus
    /// off: when the schedule is what keeps it on, the schedule is paused
    /// until the current window ends, and resumes with the next one. On
    /// turns it on by hand, as before.
    public mutating func toggle(at date: Date, calendar: Calendar = .current) {
        guard isActive(at: date, calendar: calendar) else {
            isOn = true
            schedulePausedUntil = nil
            return
        }
        isOn = false
        if scheduleEnabled, let schedule, schedule.contains(date, calendar: calendar) {
            // A window whose end cannot be worked out is paused for a day,
            // which is the longest any window lasts.
            schedulePausedUntil = schedule.end(ofWindowContaining: date, calendar: calendar)
                ?? date.addingTimeInterval(86_400)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isOn, suppressInformational, muteSounds, reduceAnimations, hideActivityLabels, schedule, scheduleEnabled
        case schedulePausedUntil
    }

    public init(from decoder: any Decoder) throws {
        let fallback = FocusPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = container.lenient(Bool.self, .isOn) ?? fallback.isOn
        suppressInformational = container.lenient(Bool.self, .suppressInformational) ?? fallback.suppressInformational
        muteSounds = container.lenient(Bool.self, .muteSounds) ?? fallback.muteSounds
        reduceAnimations = container.lenient(Bool.self, .reduceAnimations) ?? fallback.reduceAnimations
        hideActivityLabels = container.lenient(Bool.self, .hideActivityLabels) ?? fallback.hideActivityLabels
        schedule = container.lenient(DailyWindow.self, .schedule)
        scheduleEnabled = container.lenient(Bool.self, .scheduleEnabled) ?? fallback.scheduleEnabled
        schedulePausedUntil = container.lenient(Date.self, .schedulePausedUntil)
    }
}

public struct GitHubPreferences: Codable, Equatable, Sendable {
    /// Off until the user connects an account.
    public var enabled: Bool
    public var trackPullRequests: Bool
    public var monitorActions: Bool
    public var reviewNotifications: Bool
    /// How often to look at GitHub, in seconds: every 30 by default. Requests
    /// are conditional and GitHub does not count a 304 against the rate
    /// limit, so looking often at repositories that have not changed is free,
    /// and `GitHubPollBudget` stops review and check lookups when the hourly
    /// allowance runs low. At most an hour so status never goes stale longer.
    public var refreshSeconds: Int

    /// Which repositories are monitored, and which one is focused.
    public var selection: GitHubRepositorySelection

    // GitHub Mode in the notch.
    /// The GitHub button in the open notch.
    public var showNotchButton: Bool
    /// GitHub Mode itself: the button and the ⌃⌥G shortcut open it. Off hides
    /// both and keeps GitHub to the companion window and notifications.
    public var notchModeEnabled: Bool
    public var showAccount: Bool
    /// The repository name on rows and in the panel header.
    public var showRepositoryInfo: Bool
    /// Running workflows tint the GitHub button.
    public var showRunningIndicator: Bool
    /// Review requests, requested changes and conflicts tint the GitHub button.
    public var showPullRequestIndicator: Bool
    /// Failures and things waiting on you also show in the closed notch.
    public var showInClosedNotch: Bool
    public var defaultView: GitHubDefaultView
    /// The tab open last time, for "Where I left off".
    public var lastView: GitHubView
    public var density: GitHubPanelDensity
    /// Branch, commit, event and author lines on rows.
    public var showDetailedMetadata: Bool

    // Notifications and refresh.
    /// Several notices of one kind from one repository arrive as one.
    public var groupNotifications: Bool
    /// Look again every 45 seconds while a workflow is running.
    public var fastRefreshWhileRunning: Bool
    /// Per repository, keyed by GitHub repository id. A missing entry is `.all`.
    public var repositoryAlerts: [String: GitHubAlertLevel]
    /// Offer to merge pull requests GitHub says are ready. Each merge still
    /// needs its own confirmation.
    public var allowMerging: Bool
    /// The merge method last used in each repository, keyed by repository id.
    public var mergeMethods: [String: GitHubMergeMethod]

    public static let refreshRange: ClosedRange<Int> = 30...3600
    /// The intervals Settings offers.
    public static let refreshChoices: [Int] = [30, 60, 120, 300, 600, 900, 1800, 3600]

    /// "Every 30 seconds", "Every minute", "Every 5 minutes", "Every hour".
    public static func refreshLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "Every \(seconds) seconds" }
        if seconds == 60 { return "Every minute" }
        if seconds == 3600 { return "Every hour" }
        if seconds % 60 == 0 { return "Every \(seconds / 60) minutes" }
        return "Every \(seconds) seconds"
    }

    public init(
        enabled: Bool = false,
        trackPullRequests: Bool = true,
        monitorActions: Bool = true,
        reviewNotifications: Bool = true,
        refreshSeconds: Int = 30,
        selection: GitHubRepositorySelection = GitHubRepositorySelection(),
        showNotchButton: Bool = true,
        notchModeEnabled: Bool = true,
        showAccount: Bool = true,
        showRepositoryInfo: Bool = true,
        showRunningIndicator: Bool = true,
        showPullRequestIndicator: Bool = true,
        showInClosedNotch: Bool = true,
        defaultView: GitHubDefaultView = .overview,
        lastView: GitHubView = .overview,
        density: GitHubPanelDensity = .compact,
        showDetailedMetadata: Bool = true,
        groupNotifications: Bool = true,
        fastRefreshWhileRunning: Bool = true,
        repositoryAlerts: [String: GitHubAlertLevel] = [:],
        allowMerging: Bool = true,
        mergeMethods: [String: GitHubMergeMethod] = [:]
    ) {
        self.allowMerging = allowMerging
        self.mergeMethods = mergeMethods
        self.enabled = enabled
        self.trackPullRequests = trackPullRequests
        self.monitorActions = monitorActions
        self.reviewNotifications = reviewNotifications
        self.refreshSeconds = refreshSeconds
        self.selection = selection
        self.showNotchButton = showNotchButton
        self.notchModeEnabled = notchModeEnabled
        self.showAccount = showAccount
        self.showRepositoryInfo = showRepositoryInfo
        self.showRunningIndicator = showRunningIndicator
        self.showPullRequestIndicator = showPullRequestIndicator
        self.showInClosedNotch = showInClosedNotch
        self.defaultView = defaultView
        self.lastView = lastView
        self.density = density
        self.showDetailedMetadata = showDetailedMetadata
        self.groupNotifications = groupNotifications
        self.fastRefreshWhileRunning = fastRefreshWhileRunning
        self.repositoryAlerts = repositoryAlerts
    }

    public func alertLevel(for repositoryID: Int64) -> GitHubAlertLevel {
        repositoryAlerts[String(repositoryID)] ?? .all
    }

    public mutating func setAlertLevel(_ level: GitHubAlertLevel, for repositoryID: Int64) {
        repositoryAlerts[String(repositoryID)] = level == .all ? nil : level
    }

    /// Whether the GitHub button belongs in the open notch.
    public var showsNotchButton: Bool { enabled && notchModeEnabled && showNotchButton }

    private enum CodingKeys: String, CodingKey {
        case enabled, trackPullRequests, monitorActions, reviewNotifications, refreshSeconds
        case selection, showNotchButton, notchModeEnabled, showAccount, showRepositoryInfo
        case showRunningIndicator, showPullRequestIndicator, showInClosedNotch, defaultView, lastView
        case density, showDetailedMetadata, groupNotifications, fastRefreshWhileRunning, repositoryAlerts
        case allowMerging, mergeMethods
    }

    /// Keys earlier versions wrote. Read once, never written again.
    private enum LegacyKeys: String, CodingKey {
        case refreshMinutes
    }

    /// Up to 1.0.1 the interval was whole minutes, 5 unless changed. A choice
    /// someone made carries over; the old default becomes the new one.
    private static func migratedRefreshSeconds(_ decoder: any Decoder) -> Int? {
        guard let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
              let minutes = legacy.lenient(Int.self, .refreshMinutes), minutes != 5 else { return nil }
        return min(max(minutes, 2), 60) * 60
    }

    public init(from decoder: any Decoder) throws {
        let fallback = GitHubPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.lenient(Bool.self, .enabled) ?? fallback.enabled
        trackPullRequests = container.lenient(Bool.self, .trackPullRequests) ?? fallback.trackPullRequests
        monitorActions = container.lenient(Bool.self, .monitorActions) ?? fallback.monitorActions
        reviewNotifications = container.lenient(Bool.self, .reviewNotifications) ?? fallback.reviewNotifications
        refreshSeconds = container.lenient(Int.self, .refreshSeconds)
            ?? Self.migratedRefreshSeconds(decoder)
            ?? fallback.refreshSeconds
        selection = container.lenient(GitHubRepositorySelection.self, .selection) ?? fallback.selection
        showNotchButton = container.lenient(Bool.self, .showNotchButton) ?? fallback.showNotchButton
        notchModeEnabled = container.lenient(Bool.self, .notchModeEnabled) ?? fallback.notchModeEnabled
        showAccount = container.lenient(Bool.self, .showAccount) ?? fallback.showAccount
        showRepositoryInfo = container.lenient(Bool.self, .showRepositoryInfo) ?? fallback.showRepositoryInfo
        showRunningIndicator = container.lenient(Bool.self, .showRunningIndicator) ?? fallback.showRunningIndicator
        showPullRequestIndicator = container.lenient(Bool.self, .showPullRequestIndicator) ?? fallback.showPullRequestIndicator
        showInClosedNotch = container.lenient(Bool.self, .showInClosedNotch) ?? fallback.showInClosedNotch
        defaultView = container.lenient(GitHubDefaultView.self, .defaultView) ?? fallback.defaultView
        lastView = container.lenient(GitHubView.self, .lastView) ?? fallback.lastView
        density = container.lenient(GitHubPanelDensity.self, .density) ?? fallback.density
        showDetailedMetadata = container.lenient(Bool.self, .showDetailedMetadata) ?? fallback.showDetailedMetadata
        groupNotifications = container.lenient(Bool.self, .groupNotifications) ?? fallback.groupNotifications
        fastRefreshWhileRunning = container.lenient(Bool.self, .fastRefreshWhileRunning) ?? fallback.fastRefreshWhileRunning
        // Lenient per entry: an unknown level drops that entry, not the map.
        let rawAlerts = container.lenient([String: String].self, .repositoryAlerts) ?? [:]
        repositoryAlerts = rawAlerts.compactMapValues(GitHubAlertLevel.init(rawValue:))
        allowMerging = container.lenient(Bool.self, .allowMerging) ?? fallback.allowMerging
        let rawMethods = container.lenient([String: String].self, .mergeMethods) ?? [:]
        mergeMethods = rawMethods.compactMapValues(GitHubMergeMethod.init(rawValue:))
    }
}

/// Every user preference, stored as one versioned JSON value.
///
/// Decoding is deliberately forgiving: each field falls back to its default on
/// its own when missing or unreadable, and unknown keys are ignored. A file
/// written by an older or newer version therefore keeps every setting this
/// version understands instead of resetting them all.
public struct OverheadSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// The theme every installation started with before 1.3.0, when the
    /// default became Obsidian. An installation from before then that never
    /// saved a setting keeps it (`SettingsStore`).
    public static let themeBeforeObsidianWasDefault: ThemeID = .midnight

    public var version: Int

    public var launchAtLogin: Bool
    public var preferredDisplay: DisplayPreference

    public var theme: ThemeID
    public var accent: AccentChoice
    public var appearance: AppearancePreference
    public var animationIntensity: AnimationIntensity
    /// Whether a finished turn lights the closed notch at all. Its own
    /// switch: it reads no sound setting and no sound setting reads it.
    public var completionGlowEnabled: Bool
    /// Which glow shows. Kept while the glow is off, so turning it back on
    /// brings the same one back.
    public var completionGlowTheme: GlowTheme
    /// The glow's brightness, 0...1 (`CompletionGlow` draws it no fainter
    /// than its minimum). Before the switch existed, zero turned the glow off.
    public var glowIntensity: Double
    public var layout: NotchLayout
    public var density: RowDensity

    public var sessionSort: SessionSort
    public var groupByProject: Bool
    /// Days of session history to keep; nil keeps it forever.
    public var historyRetentionDays: Int?
    public var storeConversationPreviews: Bool

    public var notifications: NotificationPreferences

    public var showAgents: Bool
    /// The closed notch's one line of live activity under the camera. Only
    /// layouts with an activity label show it, and Focus can hide it.
    public var showClosedNotchActivity: Bool
    /// Lock Mode: the notch opens only when the owner opens it.
    public var notchLocked: Bool
    /// Whether requests from runs nobody is watching (`claude -p`, an SDK
    /// run with no host that answers) wait in the notch. Off, Claude Code
    /// decides them as it does without Claude Overhead.
    public var askAboutUnattendedRuns: Bool

    /// Fractions of the context window, attention < critical, within 0.3...0.99.
    public var contextAttentionThreshold: Double
    public var contextCriticalThreshold: Double
    public var usageWarningThreshold: Double
    public var showResetCountdowns: Bool
    public var showCacheMetrics: Bool

    public var github: GitHubPreferences
    public var focus: FocusPreferences

    /// A missing action is unbound.
    public var shortcuts: [ShortcutAction: KeyCombo]
    public var shortcutsEnabled: Bool

    public var dailyRecapEnabled: Bool

    /// Whether a new session is given a random character. Off by default:
    /// a session shows the Claude logo until the owner picks a character for
    /// it in the notch, which works whether this is on or off.
    public var assignCharactersAutomatically: Bool
    /// Each project's approved characters, by project key (`ProjectKey`):
    /// what automatic assignment may hand a new session there. A project
    /// without an entry draws from the whole catalogue.
    public var projectCharacterPools: [String: [String]]
    /// Most projects that may hold a pool; the rest are dropped on save.
    public static let maximumProjectCharacterPools = 512

    public static let thresholdRange: ClosedRange<Double> = 0.3...0.99
    /// Smallest gap kept between the attention and critical thresholds, so the
    /// two stages never collapse into one.
    public static let thresholdGap = 0.05

    public init() {
        version = Self.currentVersion
        launchAtLogin = false
        preferredDisplay = .notchedDisplay
        theme = .obsidian
        accent = .claude
        appearance = .system
        animationIntensity = .full
        completionGlowEnabled = true
        completionGlowTheme = .spectrum
        glowIntensity = CompletionGlow.defaultBrightness
        layout = .classic
        density = .comfortable
        sessionSort = .attentionFirst
        groupByProject = false
        historyRetentionDays = 90
        storeConversationPreviews = true
        notifications = NotificationPreferences()
        showAgents = true
        showClosedNotchActivity = true
        notchLocked = false
        askAboutUnattendedRuns = false
        contextAttentionThreshold = 0.7
        contextCriticalThreshold = 0.9
        usageWarningThreshold = 0.8
        showResetCountdowns = true
        showCacheMetrics = true
        github = GitHubPreferences()
        focus = FocusPreferences()
        shortcuts = ShortcutDefaults.bindings
        shortcutsEnabled = true
        dailyRecapEnabled = false
        assignCharactersAutomatically = false
        projectCharacterPools = [:]
    }

    /// The same settings with every value forced into its valid range. When
    /// the context thresholds cross, critical wins and attention moves below
    /// it, because the critical warning is the one that must not be lost.
    public func normalized() -> OverheadSettings {
        let defaults = OverheadSettings()
        var copy = self
        let range = Self.thresholdRange
        copy.contextCriticalThreshold = Self.clamp(
            contextCriticalThreshold,
            to: (range.lowerBound + Self.thresholdGap)...range.upperBound,
            fallback: defaults.contextCriticalThreshold
        )
        // max() guards the range against floating-point rounding below its lower bound.
        let attentionCeiling = max(range.lowerBound, copy.contextCriticalThreshold - Self.thresholdGap)
        copy.contextAttentionThreshold = Self.clamp(
            contextAttentionThreshold,
            to: range.lowerBound...attentionCeiling,
            fallback: defaults.contextAttentionThreshold
        )
        copy.usageWarningThreshold = Self.clamp(usageWarningThreshold, to: range, fallback: defaults.usageWarningThreshold)
        copy.glowIntensity = Self.clamp(glowIntensity, to: 0...1, fallback: defaults.glowIntensity)
        copy.github.refreshSeconds = min(
            max(github.refreshSeconds, GitHubPreferences.refreshRange.lowerBound),
            GitHubPreferences.refreshRange.upperBound
        )
        copy.historyRetentionDays = historyRetentionDays.map { max($0, 1) }
        copy.notifications.quietHours = notifications.quietHours?.normalized()
        copy.focus.schedule = focus.schedule?.normalized()
        copy.projectCharacterPools = Self.normalizedPools(projectCharacterPools)
        return copy
    }

    /// The layout as it should render now, after the user's other choices:
    /// Focus may hide activity labels and calm motion, the global animation
    /// intensity scales motion, agents can be turned off, and compact density
    /// wins if either the layout or the user asks for it.
    public func resolvedLayoutSpec(at date: Date = .now, calendar: Calendar = .current) -> NotchLayoutSpec {
        let base = layout.spec
        let focusActive = focus.isActive(at: date, calendar: calendar)
        var animation = base.animationScale * animationIntensity.scale
        if focusActive, focus.reduceAnimations {
            animation = min(animation, AnimationIntensity.minimal.scale)
        }
        let compact = base.expandedRowDensity == .compact || density == .compact
        return base.with(
            showsActivityLabel: base.showsActivityLabel && !(focusActive && focus.hideActivityLabels),
            showsAgentIndicator: base.showsAgentIndicator && showAgents,
            expandedShowsAgents: base.expandedShowsAgents && showAgents,
            expandedRowDensity: compact ? .compact : .comfortable,
            animationScale: animation
        )
    }

    /// Whether the closed notch shows its live activity line right now: the
    /// setting is on, the layout has an activity label, and Focus is not
    /// hiding activity labels.
    public func showsClosedNotchActivity(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        showClosedNotchActivity && resolvedLayoutSpec(at: date, calendar: calendar).showsActivityLabel
    }

    /// Pools keyed by a clean project key, without repeats, and without the
    /// empty ones: an empty pool means "no pool", which is the same as none.
    /// Ids this version does not know are kept, since another version may.
    static func normalizedPools(_ pools: [String: [String]]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for key in pools.keys.sorted() {
            guard result.count < maximumProjectCharacterPools,
                  let projectKey = ProjectKey.make(key), let ids = pools[key] else { continue }
            var seen = Set<String>()
            let unique = ids.filter { !$0.isEmpty && $0.utf8.count <= 128 && seen.insert($0).inserted }
            if !unique.isEmpty { result[projectKey] = Array(unique.prefix(256)) }
        }
        return result
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        let finite = value.isFinite ? value : fallback
        return min(max(finite, range.lowerBound), range.upperBound)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version
        case launchAtLogin, preferredDisplay
        case theme, accent, appearance, animationIntensity, glowIntensity, layout, density
        case completionGlowEnabled, completionGlowTheme
        case sessionSort, groupByProject, historyRetentionDays, storeConversationPreviews
        case notifications
        case showAgents, showClosedNotchActivity, notchLocked, askAboutUnattendedRuns
        case contextAttentionThreshold, contextCriticalThreshold, usageWarningThreshold
        case showResetCountdowns, showCacheMetrics
        case github, focus
        case shortcuts, shortcutsEnabled
        case dailyRecapEnabled
        case assignCharactersAutomatically, projectCharacterPools
    }

    public init(from decoder: any Decoder) throws {
        let d = OverheadSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version) ?? d.version
        launchAtLogin = c.lenient(Bool.self, .launchAtLogin) ?? d.launchAtLogin
        preferredDisplay = c.lenient(DisplayPreference.self, .preferredDisplay) ?? d.preferredDisplay
        theme = c.lenient(ThemeID.self, .theme) ?? d.theme
        accent = c.lenient(AccentChoice.self, .accent) ?? d.accent
        // Kept so older settings files decode; the theme now decides light or
        // dark (ThemeLibrary.windowAppearanceIsDark), so it no longer applies.
        appearance = c.lenient(AppearancePreference.self, .appearance) ?? d.appearance
        animationIntensity = c.lenient(AnimationIntensity.self, .animationIntensity) ?? d.animationIntensity
        glowIntensity = c.lenient(Double.self, .glowIntensity) ?? d.glowIntensity
        // A file from before the switch existed: a slider left at zero was
        // how the glow was turned off, and it stays off.
        completionGlowEnabled = c.lenient(Bool.self, .completionGlowEnabled) ?? (glowIntensity > 0)
        completionGlowTheme = c.lenient(GlowTheme.self, .completionGlowTheme) ?? d.completionGlowTheme
        layout = c.lenient(NotchLayout.self, .layout) ?? d.layout
        density = c.lenient(RowDensity.self, .density) ?? d.density
        sessionSort = c.lenient(SessionSort.self, .sessionSort) ?? d.sessionSort
        groupByProject = c.lenient(Bool.self, .groupByProject) ?? d.groupByProject
        // An explicit null means "keep forever"; only a missing key takes the default.
        if c.contains(.historyRetentionDays), (try? c.decodeNil(forKey: .historyRetentionDays)) == true {
            historyRetentionDays = nil
        } else {
            historyRetentionDays = c.lenient(Int.self, .historyRetentionDays) ?? d.historyRetentionDays
        }
        storeConversationPreviews = c.lenient(Bool.self, .storeConversationPreviews) ?? d.storeConversationPreviews
        notifications = c.lenient(NotificationPreferences.self, .notifications) ?? d.notifications
        showAgents = c.lenient(Bool.self, .showAgents) ?? d.showAgents
        showClosedNotchActivity = c.lenient(Bool.self, .showClosedNotchActivity) ?? d.showClosedNotchActivity
        notchLocked = c.lenient(Bool.self, .notchLocked) ?? d.notchLocked
        askAboutUnattendedRuns = c.lenient(Bool.self, .askAboutUnattendedRuns) ?? d.askAboutUnattendedRuns
        contextAttentionThreshold = c.lenient(Double.self, .contextAttentionThreshold) ?? d.contextAttentionThreshold
        contextCriticalThreshold = c.lenient(Double.self, .contextCriticalThreshold) ?? d.contextCriticalThreshold
        usageWarningThreshold = c.lenient(Double.self, .usageWarningThreshold) ?? d.usageWarningThreshold
        showResetCountdowns = c.lenient(Bool.self, .showResetCountdowns) ?? d.showResetCountdowns
        showCacheMetrics = c.lenient(Bool.self, .showCacheMetrics) ?? d.showCacheMetrics
        github = c.lenient(GitHubPreferences.self, .github) ?? d.github
        focus = c.lenient(FocusPreferences.self, .focus) ?? d.focus
        shortcuts = Self.decodeShortcuts(from: c) ?? d.shortcuts
        shortcutsEnabled = c.lenient(Bool.self, .shortcutsEnabled) ?? d.shortcutsEnabled
        dailyRecapEnabled = c.lenient(Bool.self, .dailyRecapEnabled) ?? d.dailyRecapEnabled
        assignCharactersAutomatically = c.lenient(Bool.self, .assignCharactersAutomatically)
            ?? d.assignCharactersAutomatically
        projectCharacterPools = c.lenient([String: [String]].self, .projectCharacterPools) ?? d.projectCharacterPools
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(preferredDisplay, forKey: .preferredDisplay)
        try c.encode(theme, forKey: .theme)
        try c.encode(accent, forKey: .accent)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(animationIntensity, forKey: .animationIntensity)
        try c.encode(glowIntensity, forKey: .glowIntensity)
        try c.encode(completionGlowEnabled, forKey: .completionGlowEnabled)
        try c.encode(completionGlowTheme, forKey: .completionGlowTheme)
        try c.encode(layout, forKey: .layout)
        try c.encode(density, forKey: .density)
        try c.encode(sessionSort, forKey: .sessionSort)
        try c.encode(groupByProject, forKey: .groupByProject)
        if let historyRetentionDays {
            try c.encode(historyRetentionDays, forKey: .historyRetentionDays)
        } else {
            try c.encodeNil(forKey: .historyRetentionDays)
        }
        try c.encode(storeConversationPreviews, forKey: .storeConversationPreviews)
        try c.encode(notifications, forKey: .notifications)
        try c.encode(showAgents, forKey: .showAgents)
        try c.encode(showClosedNotchActivity, forKey: .showClosedNotchActivity)
        try c.encode(notchLocked, forKey: .notchLocked)
        try c.encode(askAboutUnattendedRuns, forKey: .askAboutUnattendedRuns)
        try c.encode(contextAttentionThreshold, forKey: .contextAttentionThreshold)
        try c.encode(contextCriticalThreshold, forKey: .contextCriticalThreshold)
        try c.encode(usageWarningThreshold, forKey: .usageWarningThreshold)
        try c.encode(showResetCountdowns, forKey: .showResetCountdowns)
        try c.encode(showCacheMetrics, forKey: .showCacheMetrics)
        try c.encode(github, forKey: .github)
        try c.encode(focus, forKey: .focus)
        // Every known action is written, unbound ones as null, so a later
        // version can tell "the user removed this" from "this did not exist yet".
        var keys = c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .shortcuts)
        for action in ShortcutAction.allCases {
            let key = AnyCodingKey(action.rawValue)
            if let combo = shortcuts[action] {
                try keys.encode(combo, forKey: key)
            } else {
                try keys.encodeNil(forKey: key)
            }
        }
        try c.encode(shortcutsEnabled, forKey: .shortcutsEnabled)
        try c.encode(dailyRecapEnabled, forKey: .dailyRecapEnabled)
        try c.encode(assignCharactersAutomatically, forKey: .assignCharactersAutomatically)
        try c.encode(projectCharacterPools, forKey: .projectCharacterPools)
    }

    /// Null unbinds an action; an action absent from the file (added after it
    /// was written) gets its default binding; unknown actions are ignored.
    private static func decodeShortcuts(from container: KeyedDecodingContainer<CodingKeys>) -> [ShortcutAction: KeyCombo]? {
        guard let keys = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .shortcuts) else {
            return nil
        }
        var result = ShortcutDefaults.bindings
        for action in ShortcutAction.allCases {
            let key = AnyCodingKey(action.rawValue)
            guard keys.contains(key) else { continue }
            if (try? keys.decodeNil(forKey: key)) == true {
                result[action] = nil
            } else if let combo = keys.lenient(KeyCombo.self, key) {
                result[action] = combo
            }
        }
        return result
    }
}

/// Persists `OverheadSettings` as one JSON blob in `UserDefaults`.
///
/// One blob rather than a key per setting keeps a save atomic and lets the
/// whole value be versioned. The lock serialises access so a read-modify-write
/// through `update` cannot interleave with another thread's save.
public final class SettingsStore: @unchecked Sendable {
    public static let storageKey = "overhead.settings.v1"
    /// Where an unreadable blob is kept, so a bug never destroys the user's data.
    public static let corruptBackupKey = "overhead.settings.v1.corrupt"
    /// The sound switch from before settings were unified.
    public static let legacySoundsEnabledKey = "overhead.sound.enabled"
    /// What an installation that has run before leaves in its preferences,
    /// whether or not it ever saved a setting: the version it last launched
    /// (written when the app starts, after settings are read), that setup
    /// was finished, and the things only a used copy stores.
    public static let existingInstallationKeys = [
        "overhead.update.lastLaunchedVersion",
        "overhead.onboarding.completed",
        legacySoundsEnabledKey,
        "overhead.sound.sessions",
        "overhead.sessions.archived",
        "overhead.characters.assignments.v1",
        "overhead.integration.claude.lastReceipt",
        "overhead.folderAccess.confirmedRoots",
    ]

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored settings. When nothing is stored yet they are worked out
    /// once and saved at once, so every later launch reads the same answer:
    ///
    /// - A new installation gets the defaults.
    /// - An installation that ran before but never saved a setting keeps what
    ///   it was showing: the defaults of its day (Midnight, where the default
    ///   is now Obsidian) and the sound switch from its legacy key. The
    ///   legacy keys are left in place so an older build still finds them.
    ///
    /// A blob that cannot be read yields defaults and is copied to
    /// `corruptBackupKey` before anything can overwrite it.
    public func load() -> OverheadSettings {
        lock.withLock { loadLocked() }
    }

    public func save(_ settings: OverheadSettings) {
        lock.withLock { saveLocked(settings) }
    }

    /// Loads, applies `change`, saves and returns the normalized result as one
    /// step, so concurrent edits of different fields do not drop each other.
    @discardableResult
    public func update(_ change: (inout OverheadSettings) -> Void) -> OverheadSettings {
        lock.withLock {
            var settings = loadLocked()
            change(&settings)
            let normalized = settings.normalized()
            saveLocked(normalized)
            return normalized
        }
    }

    private func loadLocked() -> OverheadSettings {
        guard let stored = defaults.object(forKey: Self.storageKey) else {
            return migrateLegacyLocked()
        }
        guard let data = stored as? Data,
              let settings = try? JSONDecoder().decode(OverheadSettings.self, from: data)
        else {
            defaults.set(stored, forKey: Self.corruptBackupKey)
            return OverheadSettings()
        }
        return settings.normalized()
    }

    private func migrateLegacyLocked() -> OverheadSettings {
        var settings = OverheadSettings()
        if Self.existingInstallationKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            // This copy was in use before it had anything to save. A default
            // that changed since must not change what its owner sees.
            settings.theme = OverheadSettings.themeBeforeObsidianWasDefault
        }
        if let soundsEnabled = defaults.object(forKey: Self.legacySoundsEnabledKey) as? Bool {
            settings.notifications.soundsEnabled = soundsEnabled
        }
        // Saving now is what makes this run once: the next load finds the
        // blob and never asks again. Without it, a new installation would
        // look like an old one on its second launch, once setup has left its
        // own marks, and lose the theme it started with.
        saveLocked(settings)
        return settings
    }

    private func saveLocked(_ settings: OverheadSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(settings.normalized()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - Lenient decoding

/// A string coding key for maps keyed by enum raw values.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or nil when it is missing, null or unreadable.
    /// Settings use this for every field so one bad value costs only itself.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}
