import Foundation

/// The notification sound the owner picked. All short and quiet.
public enum NotificationSoundChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Claude Overhead's own pixel chime: a rising cue for a finished turn,
    /// a double blip when Claude needs you.
    case chime
    case tink
    case pop
    case glass
    case purr

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chime: "Pixel chime"
        case .tink: "Tink"
        case .pop: "Pop"
        case .glass: "Glass"
        case .purr: "Purr"
        }
    }

    /// The macOS system sound to play, or nil for the built-in chime.
    public var systemSoundName: String? {
        switch self {
        case .chime: nil
        case .tink: "Tink"
        case .pop: "Pop"
        case .glass: "Glass"
        case .purr: "Purr"
        }
    }
}

/// Sound level, independent of the Mac's own volume (which still applies on
/// top, as do mute and the output device).
public enum NotificationSoundVolume {
    public static let range: ClosedRange<Double> = 0.05...1
    public static let defaultValue = 0.5

    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension OverheadEventKind {
    /// Events that belong to one Claude session, whose sound that session's
    /// own toggle decides.
    public var isSessionSound: Bool {
        switch self {
        case .permissionRequested, .questionAsked, .sessionFailed, .sessionCompleted,
             .agentCompleted, .contextWarning, .sessionStarted:
            true
        default:
            false
        }
    }
}

/// Which Claude sessions may make sounds. Every session starts silent; the
/// owner turns sound on per session in the notch. An entry lives as long as
/// its session: it goes when the session ends, or after a week unseen.
public struct SessionSoundPreferences: Codable, Equatable, Sendable {
    /// Session id to the last time the session was seen or toggled.
    public private(set) var enabledSessions: [String: Date]

    public static let retention: TimeInterval = 7 * 86_400

    public init(enabledSessions: [String: Date] = [:]) {
        self.enabledSessions = enabledSessions
    }

    public func isEnabled(_ sessionID: String) -> Bool {
        enabledSessions[sessionID] != nil
    }

    public mutating func setEnabled(_ enabled: Bool, for sessionID: String, at now: Date) {
        guard !sessionID.isEmpty else { return }
        enabledSessions[sessionID] = enabled ? now : nil
    }

    /// Flips one session and returns its new state. Other sessions never change.
    @discardableResult
    public mutating func toggle(_ sessionID: String, at now: Date) -> Bool {
        let enabled = !isEnabled(sessionID)
        setEnabled(enabled, for: sessionID, at: now)
        return enabled
    }

    /// Keeps the entries of sessions that are still around from expiring.
    public mutating func touch(_ sessionIDs: some Sequence<String>, at now: Date) {
        for id in sessionIDs where enabledSessions[id] != nil {
            enabledSessions[id] = now
        }
    }

    public mutating func forget(_ sessionID: String) {
        enabledSessions[sessionID] = nil
    }

    public mutating func prune(now: Date) {
        enabledSessions = enabledSessions.filter { now.timeIntervalSince($0.value) < Self.retention }
    }
}

/// Decides whether an announced event plays its sound: the notification
/// policy must allow it, a session's event needs that session's toggle, and
/// one session sounds at most once per `minimumInterval`, so a burst of
/// events (permission, then question, then completion) is a single sound.
public struct SessionSoundGate: Sendable {
    public static let minimumInterval: TimeInterval = 2

    private var lastPlayed: [String: Date] = [:]

    public init() {}

    public mutating func allows(
        _ kind: OverheadEventKind,
        sessionID: String?,
        policyAllows: Bool,
        preferences: SessionSoundPreferences,
        now: Date
    ) -> Bool {
        guard policyAllows else { return false }
        guard kind.isSessionSound else { return true }
        guard let sessionID, preferences.isEnabled(sessionID) else { return false }
        if let last = lastPlayed[sessionID], now.timeIntervalSince(last) >= 0,
           now.timeIntervalSince(last) < Self.minimumInterval {
            return false
        }
        lastPlayed[sessionID] = now
        return true
    }

    public mutating func forget(_ sessionID: String) {
        lastPlayed[sessionID] = nil
    }
}

// MARK: - Lock Mode

/// Lock Mode keeps the notch closed until the owner opens it. It changes
/// only what the notch shows: every session is still monitored, sounds the
/// owner enabled still play, and a permission request or question still
/// waits in the notch, never approved or dropped, until the owner opens it.
public enum NotchLockPolicy {
    public enum Trigger: Sendable, CaseIterable {
        /// Claude is waiting on a permission, a question or a decision.
        case ownerRequest
        case sessionFailure
        case updateNotice
        case hover
        /// A click on the notch, a shortcut, the GitHub button or badge.
        case ownerAction
    }

    /// `isHidden` is the eye button (`NotchVisibilityPolicy`): hidden, the
    /// notch opens only on the owner's click, except for a request Claude is
    /// blocked on, which follows Lock Mode exactly as it does when shown.
    public static func opens(
        _ trigger: Trigger,
        isLocked: Bool,
        isHidden: Bool = false,
        layoutExpandsOnHover: Bool = true
    ) -> Bool {
        switch trigger {
        case .ownerAction: true
        case .ownerRequest: !isLocked
        case .hover: layoutExpandsOnHover && !isLocked && !isHidden
        case .sessionFailure, .updateNotice: !isLocked && !isHidden
        }
    }

    /// Unlocking with a request already waiting opens the notch on it, as an
    /// unlocked notch would have done when the request arrived.
    public static func opensOnUnlock(hasPendingOwnerRequest: Bool) -> Bool {
        hasPendingOwnerRequest
    }
}
