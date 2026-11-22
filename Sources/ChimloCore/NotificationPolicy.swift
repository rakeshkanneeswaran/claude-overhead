import Foundation

/// How hard an event may interrupt. Ordered: ambient < informational < critical.
public enum NotificationPriority: String, Codable, Sendable, Comparable, CaseIterable {
    /// Background state; shown in the notch, never announced.
    case ambient
    /// Worth knowing soon; shown, never forces the panel open.
    case informational
    /// Needs the user now; opens the panel.
    case critical

    private var rank: Int {
        switch self {
        case .ambient: 0
        case .informational: 1
        case .critical: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Everything Overhead can tell the user about.
public enum OverheadEventKind: String, Codable, Sendable, CaseIterable {
    case permissionRequested
    case questionAsked
    case sessionFailed
    case integrationError
    case sessionCompleted
    case agentCompleted
    case contextWarning
    case usageWarning
    case sessionStarted
    case activity
    case githubCIFailed
    case githubCIPassed
    case githubReviewRequested
    case githubChangesRequested
    case githubApproved
    case githubMerged
    case githubNewComments

    /// GitHub events never outrank informational: they matter, but none of
    /// them blocks the Claude session in front of the user.
    public var priority: NotificationPriority {
        switch self {
        case .permissionRequested, .questionAsked, .sessionFailed, .integrationError:
            .critical
        case .sessionCompleted, .agentCompleted, .contextWarning, .usageWarning,
             .githubCIFailed, .githubReviewRequested, .githubChangesRequested,
             .githubApproved, .githubMerged:
            .informational
        case .sessionStarted, .activity, .githubCIPassed, .githubNewComments:
            .ambient
        }
    }

    public var displayName: String {
        switch self {
        case .permissionRequested: "Permission requests"
        case .questionAsked: "Questions from Claude"
        case .sessionFailed: "Session failures"
        case .integrationError: "Integration errors"
        case .sessionCompleted: "Session completed"
        case .agentCompleted: "Agent completed"
        case .contextWarning: "Context running low"
        case .usageWarning: "Usage limit approaching"
        case .sessionStarted: "Session started"
        case .activity: "Activity"
        case .githubCIFailed: "CI failed"
        case .githubCIPassed: "CI passed"
        case .githubReviewRequested: "Review requested"
        case .githubChangesRequested: "Changes requested"
        case .githubApproved: "Pull request approved"
        case .githubMerged: "Pull request merged"
        case .githubNewComments: "New comments"
        }
    }

    public var isGitHub: Bool {
        switch self {
        case .githubCIFailed, .githubCIPassed, .githubReviewRequested, .githubChangesRequested,
             .githubApproved, .githubMerged, .githubNewComments:
            true
        default:
            false
        }
    }

    /// Claude stops until the user answers. These can never be hidden: a
    /// hidden permission prompt leaves the session stuck with no visible cause.
    public var blocksClaude: Bool {
        self == .permissionRequested || self == .questionAsked
    }

    var isCompletion: Bool {
        self == .sessionCompleted || self == .agentCompleted
    }

    var isGitHubActions: Bool {
        self == .githubCIFailed || self == .githubCIPassed
    }

    var isGitHubReview: Bool {
        switch self {
        case .githubReviewRequested, .githubChangesRequested, .githubApproved, .githubNewComments: true
        default: false
        }
    }
}

/// The user's choice for one event kind.
public struct EventPreference: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var sound: Bool
    /// A macOS notification banner. Off by default everywhere: banners need
    /// macOS notification permission, so the user opts in deliberately.
    public var systemBanner: Bool

    public init(enabled: Bool, sound: Bool, systemBanner: Bool) {
        self.enabled = enabled
        self.sound = sound
        self.systemBanner = systemBanner
    }

    /// Defaults per kind: critical events are on with sound; informational
    /// ones are on, but only a finished session makes a sound; ambient ones
    /// stay in the notch. GitHub starts with only the events that ask
    /// something of the user (failed CI, review requested, changes requested).
    public static func defaultPreference(for kind: OverheadEventKind) -> EventPreference {
        if kind.isGitHub {
            let wanted: Set<OverheadEventKind> = [.githubCIFailed, .githubReviewRequested, .githubChangesRequested]
            return EventPreference(enabled: wanted.contains(kind), sound: false, systemBanner: false)
        }
        switch kind.priority {
        case .critical:
            return EventPreference(enabled: true, sound: true, systemBanner: false)
        case .informational:
            return EventPreference(enabled: true, sound: kind == .sessionCompleted, systemBanner: false)
        case .ambient:
            return EventPreference(enabled: true, sound: false, systemBanner: false)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, sound, systemBanner
    }

    /// Missing fields fall back to `false` individually rather than failing,
    /// so one odd entry never discards the rest of the file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.lenient(Bool.self, .enabled) ?? false
        sound = container.lenient(Bool.self, .sound) ?? false
        systemBanner = container.lenient(Bool.self, .systemBanner) ?? false
    }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    /// Global mute: false silences every event regardless of its own setting.
    public var soundsEnabled: Bool
    /// Only kinds the user changed; a missing kind uses its default, so new
    /// kinds added later get sensible behaviour without a migration.
    public var perEvent: [OverheadEventKind: EventPreference]
    public var quietHours: DailyWindow?
    public var quietHoursEnabled: Bool
    /// Tag completions with one group key so a burst of finished sessions
    /// collapses into a single notice.
    public var groupCompletions: Bool

    public init(
        soundsEnabled: Bool = true,
        perEvent: [OverheadEventKind: EventPreference] = [:],
        quietHours: DailyWindow? = nil,
        quietHoursEnabled: Bool = false,
        groupCompletions: Bool = true
    ) {
        self.soundsEnabled = soundsEnabled
        self.perEvent = perEvent
        self.quietHours = quietHours
        self.quietHoursEnabled = quietHoursEnabled
        self.groupCompletions = groupCompletions
    }

    public func preference(for kind: OverheadEventKind) -> EventPreference {
        perEvent[kind] ?? .defaultPreference(for: kind)
    }

    public func quietHoursActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled, let quietHours else { return false }
        return quietHours.contains(date, calendar: calendar)
    }

    private enum CodingKeys: String, CodingKey {
        case soundsEnabled, perEvent, quietHours, quietHoursEnabled, groupCompletions
    }

    public init(from decoder: any Decoder) throws {
        let fallback = NotificationPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        soundsEnabled = container.lenient(Bool.self, .soundsEnabled) ?? fallback.soundsEnabled
        quietHours = container.lenient(DailyWindow.self, .quietHours)
        quietHoursEnabled = container.lenient(Bool.self, .quietHoursEnabled) ?? fallback.quietHoursEnabled
        groupCompletions = container.lenient(Bool.self, .groupCompletions) ?? fallback.groupCompletions
        // Keyed by raw value so an event kind from a newer version, or one
        // malformed entry, is skipped instead of failing the whole map.
        var events: [OverheadEventKind: EventPreference] = [:]
        if let nested = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .perEvent) {
            for key in nested.allKeys {
                guard let kind = OverheadEventKind(rawValue: key.stringValue),
                      let preference = nested.lenient(EventPreference.self, key)
                else { continue }
                events[kind] = preference
            }
        }
        perEvent = events
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(soundsEnabled, forKey: .soundsEnabled)
        try container.encodeIfPresent(quietHours, forKey: .quietHours)
        try container.encode(quietHoursEnabled, forKey: .quietHoursEnabled)
        try container.encode(groupCompletions, forKey: .groupCompletions)
        var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .perEvent)
        for kind in OverheadEventKind.allCases {
            guard let preference = perEvent[kind] else { continue }
            try nested.encode(preference, forKey: AnyCodingKey(kind.rawValue))
        }
    }
}

/// What to do with one event.
public struct NotificationDecision: Equatable, Sendable {
    public var showInNotch: Bool
    public var expandNotch: Bool
    public var playSound: Bool
    public var postSystemBanner: Bool
    /// Events sharing a key may be shown as one grouped notice.
    public var groupKey: String?

    public init(
        showInNotch: Bool,
        expandNotch: Bool,
        playSound: Bool,
        postSystemBanner: Bool,
        groupKey: String? = nil
    ) {
        self.showInNotch = showInNotch
        self.expandNotch = expandNotch
        self.playSound = playSound
        self.postSystemBanner = postSystemBanner
        self.groupKey = groupKey
    }

    public static let suppressed = NotificationDecision(
        showInNotch: false,
        expandNotch: false,
        playSound: false,
        postSystemBanner: false
    )
}

/// The moment a decision is made in. Passed in, never read from the system,
/// so the policy is deterministic under test.
public struct NotificationContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// macOS Focus, if the app can tell; false when unknown.
    public var systemFocusActive: Bool

    public init(now: Date = .now, calendar: Calendar = .current, systemFocusActive: Bool = false) {
        self.now = now
        self.calendar = calendar
        self.systemFocusActive = systemFocusActive
    }
}

/// Remembers which events were delivered and when, so a hook that fires twice
/// or a poller that reports the same CI run again does not interrupt twice.
/// Bounded so a long-running app cannot grow it without limit.
public struct DeliveryLedger: Sendable, Equatable {
    public static let capacity = 500

    private var deliveries: [String: Date] = [:]

    public init() {}

    public var count: Int { deliveries.count }

    public func lastDelivery(of key: String) -> Date? {
        deliveries[key]
    }

    /// Records a delivery. When full, the oldest entry goes first: it is the
    /// one least likely to still be inside a dedupe window.
    public mutating func record(_ key: String, at date: Date) {
        deliveries[key] = date
        while deliveries.count > Self.capacity,
              let oldest = deliveries.min(by: { $0.value < $1.value })?.key {
            deliveries.removeValue(forKey: oldest)
        }
    }
}

/// Decides what interrupts the user. Pure: the same inputs give the same
/// decision, and the only state is the ledger the caller owns.
///
/// Rules (rule 8 is checked first, then 1 to 7):
/// 1. A disabled kind is suppressed, except `permissionRequested` and
///    `questionAsked`: they block Claude, so they always show in the notch and
///    expand it. Their sound and banner still follow their preference.
/// 2. A key delivered within the last 10 minutes is a duplicate and is
///    suppressed. Critical kinds use 30 seconds instead: a permission asked
///    again after that is a new request and must be seen.
/// 3. Quiet state (Overhead Focus active, quiet hours, or macOS Focus):
///    informational and ambient events never sound or post banners;
///    informational events show in the notch only, or are suppressed when
///    `focus.suppressInformational` is on. Critical events still show and
///    expand; their sound is muted by quiet hours, or by Focus (Overhead or
///    macOS) when `focus.muteSounds` is on; their banner follows its
///    preference, and macOS applies its own Focus filtering to banners.
/// 4. Ambient: shown in the notch only; never expands, sounds or posts a banner.
/// 5. Informational: shown, never expands; sound needs both its preference and
///    the global sound switch; banner follows its preference.
/// 6. Critical: shown and expanded; sound as in 5; banner per its preference.
/// 7. With `groupCompletions`, session and agent completions carry the group
///    key "completions".
/// 8. GitHub kinds are suppressed entirely while GitHub is disabled, and when
///    the matching GitHub switch (Actions, pull requests, reviews) is off, so
///    turning a feature off also stops anything already in flight.
///
/// Every delivered (not suppressed) event is recorded in the ledger under its
/// kind and key. Suppressed duplicates are not recorded, so the window counts
/// from the last real delivery and a repeating event resurfaces periodically
/// rather than being hidden forever. An empty key opts out of deduplication.
public enum NotificationPolicy {
    public static let completionsGroupKey = "completions"
    public static let duplicateWindow: TimeInterval = 10 * 60
    public static let criticalDuplicateWindow: TimeInterval = 30

    public static func decide(
        _ kind: OverheadEventKind,
        key: String,
        settings: OverheadSettings,
        context: NotificationContext,
        ledger: inout DeliveryLedger
    ) -> NotificationDecision {
        // Rule 8.
        if kind.isGitHub, !gitHubAllows(kind, settings.github) {
            return .suppressed
        }

        // Rule 1.
        let preference = settings.notifications.preference(for: kind)
        if !preference.enabled, !kind.blocksClaude {
            return .suppressed
        }

        // Rule 2. Keys are namespaced by kind so one session's completion
        // cannot swallow its own permission request.
        let ledgerKey = "\(kind.rawValue)|\(key)"
        if !key.isEmpty, let last = ledger.lastDelivery(of: ledgerKey) {
            let window = kind.priority == .critical ? criticalDuplicateWindow : duplicateWindow
            let elapsed = context.now.timeIntervalSince(last)
            if elapsed >= 0, elapsed < window {
                return .suppressed
            }
        }

        // Rule 3 inputs.
        let overheadFocus = settings.focus.isActive(at: context.now, calendar: context.calendar)
        let inFocus = overheadFocus || context.systemFocusActive
        let quietHours = settings.notifications.quietHoursActive(at: context.now, calendar: context.calendar)
        let isQuiet = inFocus || quietHours
        let soundAllowed = preference.sound && settings.notifications.soundsEnabled

        var decision: NotificationDecision
        switch kind.priority {
        case .ambient:
            // Rule 4.
            decision = NotificationDecision(showInNotch: true, expandNotch: false, playSound: false, postSystemBanner: false)
        case .informational:
            // Rule 3: optionally hide informational events while quiet.
            if isQuiet, settings.focus.suppressInformational {
                return .suppressed
            }
            // Rules 3 and 5.
            decision = NotificationDecision(
                showInNotch: true,
                expandNotch: false,
                playSound: soundAllowed && !isQuiet,
                postSystemBanner: preference.systemBanner && !isQuiet
            )
        case .critical:
            // Rules 3 and 6.
            let mutedByFocus = inFocus && settings.focus.muteSounds
            decision = NotificationDecision(
                showInNotch: true,
                expandNotch: true,
                playSound: soundAllowed && !mutedByFocus && !quietHours,
                postSystemBanner: preference.systemBanner
            )
        }

        // Rule 7.
        if settings.notifications.groupCompletions, kind.isCompletion {
            decision.groupKey = completionsGroupKey
        }

        if !key.isEmpty {
            ledger.record(ledgerKey, at: context.now)
        }
        return decision
    }

    private static func gitHubAllows(_ kind: OverheadEventKind, _ github: GitHubPreferences) -> Bool {
        guard github.enabled else { return false }
        if kind.isGitHubActions { return github.monitorActions }
        if kind.isGitHubReview { return github.trackPullRequests && github.reviewNotifications }
        return github.trackPullRequests
    }
}
