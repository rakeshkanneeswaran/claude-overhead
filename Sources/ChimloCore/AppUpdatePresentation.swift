import Foundation

// MARK: - Lifecycle

/// Where an update attempt stands: checking, available, downloading,
/// preparing (verifying and unpacking), installing, restarting, and then
/// updated. Every attempt ends in `upToDate`, `updated` or `failed`, and none
/// of those stays in the notch for good (see `AppUpdateNotice`).
public enum AppUpdatePhase: Equatable, Sendable {
    case checking
    /// The version Sparkle found, when the feed names one.
    case available(version: String?)
    case upToDate
    case downloading(progress: Double?)
    case preparing
    case installing
    case restarting
    /// Shown once, on the first launch of the new version.
    case updated(version: String)
    case failed(AppUpdateFailure)
}

// MARK: - Failures

/// One error code, as Sparkle or the URL loading system reports it.
public struct AppUpdateErrorCode: Equatable, Sendable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// Why an update attempt failed, in words the owner can act on. Built from
/// Sparkle's error codes (`SUErrors.h`) and any URL error underneath them.
public enum AppUpdateFailure: Equatable, Sendable {
    /// This build has no update feed or signing key (development builds, and
    /// releases 1.0.0 to 1.0.3, which shipped without them).
    case notConfigured
    case offline
    /// GitHub answered, but the update feed was missing or failed to load.
    case releaseUnavailable
    /// The feed loaded but could not be read or was not signed by us.
    case releaseUnreadable
    case downloadFailed
    case damagedDownload
    /// The download is not signed with Claude Overhead's key. Refused.
    case signatureMismatch
    case noPermission
    case installFailed
    case runningFromDiskImage
    case translocated
    case cancelled
    /// The newest version needs a newer macOS than this Mac runs.
    case requiresNewerSystem
    case unknown(String)

    public static let sparkleDomain = "SUSparkleErrorDomain"
    public static let urlDomain = NSURLErrorDomain
    public static let installCommand =
        "curl -fsSL https://github.com/rakeshkanneeswaran/claude-overhead/releases/latest/download/install.sh | bash"

    /// Network failures that mean "could not reach GitHub at all".
    private static let unreachableURLCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
    ]

    /// Classifies an updater error. `underlying` lists the errors beneath it,
    /// nearest first; a network failure anywhere underneath means offline.
    public init(
        error: AppUpdateErrorCode,
        underlying: [AppUpdateErrorCode] = [],
        description: String = ""
    ) {
        let chain = [error] + underlying
        if chain.contains(where: { $0.domain == Self.urlDomain && Self.unreachableURLCodes.contains($0.code) }) {
            self = .offline
            return
        }
        // Sparkle often wraps the decisive error in a generic install error, so
        // a refused signature or a damaged archive anywhere underneath wins.
        let sparkleCodes = chain.filter { $0.domain == Self.sparkleDomain }.map(\.code)
        if sparkleCodes.contains(where: { $0 == 3001 || $0 == 3002 }) {
            self = .signatureMismatch
            return
        }
        if sparkleCodes.contains(3000) {
            self = .damagedDownload
            return
        }
        guard error.domain == Self.sparkleDomain else {
            self = error.domain == Self.urlDomain ? .releaseUnavailable : .unknown(description)
            return
        }
        switch error.code {
        case 1...7: self = .notConfigured            // no key, insecure or invalid feed, bad host bundle
        case 1000: self = .releaseUnreadable         // appcast parse error
        case 1002, 1004: self = .releaseUnavailable  // appcast failed to load
        case 1003: self = .runningFromDiskImage
        case 1005: self = .translocated
        case 2000, 2001: self = .downloadFailed
        case 3000: self = .damagedDownload
        case 3001, 3002: self = .signatureMismatch
        case 4001, 4012: self = .noPermission
        case 4007, 4008: self = .cancelled
        case 4000, 4002...4006, 4009, 4010: self = .installFailed
        default: self = .unknown(description)
        }
    }

    /// One short line for the notch.
    public var summary: String {
        switch self {
        case .notConfigured: "This copy can't update itself"
        case .offline: "Can't reach GitHub"
        case .releaseUnavailable: "The update feed didn't load"
        case .releaseUnreadable: "The update feed is invalid"
        case .downloadFailed: "The download didn't finish"
        case .damagedDownload: "The download was damaged"
        case .signatureMismatch: "The update isn't signed by Claude Overhead"
        case .noPermission: "No permission to replace the app"
        case .installFailed: "Installing the update failed"
        case .runningFromDiskImage: "Running from the disk image"
        case .translocated: "Running from a temporary copy"
        case .cancelled: "The update was cancelled"
        case .requiresNewerSystem: "The new version needs a newer macOS"
        case let .unknown(description): description.isEmpty ? "Something went wrong" : description
        }
    }

    /// What happened to the installed app, and what to do next.
    public var recovery: String {
        switch self {
        case .notConfigured:
            "Update once from Terminal with the install command; later versions update themselves."
        case .offline:
            "Check your internet connection, then try again."
        case .releaseUnavailable:
            "Nothing was downloaded. Try again in a few minutes."
        case .releaseUnreadable:
            "Nothing was downloaded. Try again later, or update from Terminal."
        case .downloadFailed, .damagedDownload:
            "Nothing was installed. Try again."
        case .signatureMismatch:
            "It was refused, and nothing was installed."
        case .noPermission:
            "Your current version is unchanged. Update from Terminal, or move Claude Overhead to Applications."
        case .installFailed:
            "Your current version is unchanged. Try again, or update from Terminal."
        case .runningFromDiskImage:
            "Move Claude Overhead to Applications, then open it from there."
        case .translocated:
            "Move Claude Overhead to Applications, then open it from there."
        case .cancelled:
            "Nothing changed."
        case .requiresNewerSystem:
            "You're on the newest version this Mac can run."
        case .unknown:
            "Your current version is unchanged. Try again, or update from Terminal."
        }
    }

    /// Trying again cannot help when the build has no feed, or when the
    /// newest version cannot run on this Mac.
    public var isRetryable: Bool {
        switch self {
        case .notConfigured, .requiresNewerSystem, .runningFromDiskImage, .translocated: false
        default: true
        }
    }

    /// The owner had already chosen to install when this failed (during the
    /// download, verification or install), so a retry installs what it
    /// finds instead of offering it again.
    public var retryInstallsDirectly: Bool {
        switch self {
        case .downloadFailed, .damagedDownload, .signatureMismatch, .installFailed, .noPermission, .cancelled: true
        case .notConfigured, .offline, .releaseUnavailable, .releaseUnreadable, .runningFromDiskImage,
             .translocated, .requiresNewerSystem, .unknown: false
        }
    }

    /// Whether Terminal's install command is the way forward.
    public var suggestsInstallCommand: Bool {
        switch self {
        case .notConfigured, .releaseUnreadable, .noPermission, .installFailed, .unknown: true
        default: false
        }
    }
}

// MARK: - Presentation

public struct AppUpdatePresentation: Equatable, Sendable {
    public static let availableTitle = "Update to latest version"

    public let phase: AppUpdatePhase

    public init(phase: AppUpdatePhase) {
        self.phase = phase
    }

    /// The notch's headline.
    public var title: String {
        switch phase {
        case .checking: "Checking for updates…"
        case let .available(version): version.map { "Update to \($0)" } ?? Self.availableTitle
        case .upToDate: "Claude Overhead is up to date"
        case .downloading:
            if let progress = normalizedProgress {
                "Downloading update \(Int((progress * 100).rounded()))%"
            } else {
                "Downloading update…"
            }
        case .preparing: "Verifying update…"
        case .installing: "Installing update…"
        case .restarting: "Restarting Claude Overhead…"
        case let .updated(version): "Updated to \(version)"
        case .failed: "Update failed"
        }
    }

    /// The notch's second line, when there is one.
    public var detail: String? {
        switch phase {
        case let .failed(failure): failure.summary
        case .available: "Downloads, verifies and restarts. Settings stay."
        default: nil
        }
    }

    /// Settings' status line: the full story for a failure.
    public var statusText: String {
        switch phase {
        case .checking: "Checking for updates…"
        case let .available(version): version.map { "Version \($0) is available" } ?? "Update available"
        case .upToDate: "Claude Overhead is up to date"
        case .downloading:
            if let progress = normalizedProgress {
                "Downloading update: \(Int((progress * 100).rounded()))%"
            } else {
                "Downloading update…"
            }
        case .preparing: "Verifying the update…"
        case .installing: "Installing the update…"
        case .restarting: "Restarting to finish the update…"
        case let .updated(version): "Updated to \(version)"
        case let .failed(failure): "Update failed: \(failure.summary). \(failure.recovery)"
        }
    }

    public var actionTitle: String {
        switch phase {
        case .available: title
        case .checking: "Checking…"
        case .upToDate, .updated: "Check Again"
        case .downloading: "Downloading…"
        case .preparing: "Verifying…"
        case .installing: "Installing…"
        case .restarting: "Restarting…"
        case let .failed(failure): failure.isRetryable ? "Try Again" : "Check Again"
        }
    }

    public var isAvailable: Bool {
        if case .available = phase { return true }
        return false
    }

    public var failure: AppUpdateFailure? {
        if case let .failed(failure) = phase { return failure }
        return nil
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .preparing, .installing, .restarting: true
        case .available, .upToDate, .updated, .failed: false
        }
    }

    public var isActionable: Bool { !isBusy }

    /// Finished attempts and offers can be closed from the notch.
    public var isDismissible: Bool { !isBusy }

    /// How long a finished attempt stays in the notch on its own. An offer
    /// stays until it is installed or dismissed; busy states until they end.
    public var notchLifetime: TimeInterval? {
        switch phase {
        case .updated: 8
        case .upToDate: 4
        case .failed: 60
        case .checking, .available, .downloading, .preparing, .installing, .restarting: nil
        }
    }

    /// Stages of one attempt. A new stage brings a dismissed row back;
    /// download progress within a stage does not.
    public var stage: Int {
        switch phase {
        case .checking: 0
        case .available: 1
        case .downloading: 2
        case .preparing: 3
        case .installing: 4
        case .restarting: 5
        case .updated: 6
        case .upToDate: 7
        case .failed: 8
        }
    }

    public var normalizedProgress: Double? {
        guard case let .downloading(progress?) = phase else { return nil }
        return min(1, max(0, progress))
    }
}

// MARK: - The notch row

/// The update row in the notch. It shows the latest state until the owner
/// closes it or a finished state's lifetime runs out, so a failure can never
/// stay in the notch indefinitely. Settings keeps the latest state either way.
public struct AppUpdateNotice: Equatable, Sendable {
    public private(set) var presentation: AppUpdatePresentation?
    public private(set) var isDismissed = false
    public private(set) var shownAt: Date?

    public init() {}

    public mutating func show(_ presentation: AppUpdatePresentation?, at now: Date) {
        defer { self.presentation = presentation }
        guard let presentation else {
            isDismissed = false
            shownAt = nil
            return
        }
        if presentation.stage != self.presentation?.stage {
            isDismissed = false
            shownAt = now
        }
    }

    public mutating func dismiss() {
        guard presentation?.isDismissible == true else { return }
        isDismissed = true
    }

    /// When a finished state leaves the notch on its own.
    public var expiresAt: Date? {
        guard let shownAt, let lifetime = presentation?.notchLifetime else { return nil }
        return shownAt.addingTimeInterval(lifetime)
    }

    public func isVisible(at now: Date) -> Bool {
        guard let presentation, !isDismissed else { return false }
        // A check that found nothing answers in Settings, where it was asked.
        if presentation.phase == .upToDate { return false }
        if let expiresAt, now >= expiresAt { return false }
        return true
    }
}

public enum AppUpdatePresentationPolicy {
    /// Whether the update row takes the notch's idle panel. Claude's own
    /// requests and onboarding always come first.
    public static func shouldTakeIdlePanel(
        notice: AppUpdateNotice,
        now: Date,
        hasOwnerInteraction: Bool,
        isOnboarding: Bool
    ) -> Bool {
        guard !hasOwnerInteraction, !isOnboarding else { return false }
        return notice.isVisible(at: now)
    }
}

// MARK: - Versions

/// A dotted version such as "1.0.4", compared number by number.
public struct AppVersion: Comparable, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        components = numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

public enum AppUpdateLaunch {
    /// The version to announce as "Updated to …" on this launch: only the
    /// first launch after moving to a newer version.
    public static func updatedVersion(previous: String?, current: String) -> String? {
        guard let previous,
              let old = AppVersion(previous),
              let new = AppVersion(current),
              new > old else { return nil }
        return current
    }
}
