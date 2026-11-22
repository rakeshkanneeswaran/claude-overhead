import Foundation

// MARK: - Alerts

/// How loud an alert is on the GitHub badge. Red beats amber.
public enum GitHubAlertSeverity: Int, Codable, Sendable, Comparable {
    /// Amber: a review waits on the owner, or their pull request has
    /// requested changes, a conflict, or failing checks.
    case attention = 0
    /// Red: a workflow run failed.
    case failure = 1

    public static func < (lhs: GitHubAlertSeverity, rhs: GitHubAlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension GitHubAttention {
    /// A stable identity for this alert, so a dismissal holds across
    /// refreshes and restarts, while something genuinely new gets a new id:
    ///
    /// - a failed run is one run attempt, so the next failure (a new run, or
    ///   a re-run that fails again) is new;
    /// - failing checks are tied to the pull request's head commit, so a new
    ///   commit that fails again is new;
    /// - a conflict, requested changes, or a review request belong to the
    ///   pull request until they clear; if they come back after clearing,
    ///   the dismissal ledger treats them as new.
    public var alertID: String {
        switch self {
        case let .failedRun(run):
            "run|\(run.repository.lowercased())|\(run.id).\(run.runAttempt ?? 1)"
        case let .ciFailing(pr):
            "ci|\(pr.repository.lowercased())|\(pr.number)@\(pr.headSha ?? "-")"
        case let .mergeConflict(pr):
            "conflict|\(pr.repository.lowercased())|\(pr.number)"
        case let .changesRequested(pr):
            "changes|\(pr.repository.lowercased())|\(pr.number)"
        case let .reviewRequested(pr):
            "review|\(pr.repository.lowercased())|\(pr.number)"
        }
    }

    public var severity: GitHubAlertSeverity {
        isFailedRun ? .failure : .attention
    }

    /// `owner/name`, as GitHub reports it.
    public var repository: String {
        switch self {
        case let .failedRun(run): run.repository
        case let .mergeConflict(pr), let .changesRequested(pr), let .ciFailing(pr), let .reviewRequested(pr):
            pr.repository
        }
    }
}

public enum GitHubAlertID {
    /// The lowercased `owner/name` an alert id belongs to.
    public static func repository(of id: String) -> String? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// The alert's kind: run, ci, conflict, changes or review.
    public static func kind(of id: String) -> String? {
        id.split(separator: "|", maxSplits: 1).first.map(String.init)
    }
}

// MARK: - Dismissals

/// Which alerts the owner dismissed. Dismissing only hides an alert from the
/// badge; GitHub itself is never touched, and the data behind the alert
/// stays exactly as GitHub reports it.
///
/// An alert that clears (the run is superseded, the review is done) is
/// marked resolved rather than forgotten, and is forgotten later; if the same
/// id ever comes back after clearing, that is a new event and alerts again.
public struct GitHubAlertDismissals: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var dismissedAt: Date
        /// When the alert was last seen gone from GitHub's data.
        public var resolvedAt: Date?

        public init(dismissedAt: Date, resolvedAt: Date? = nil) {
            self.dismissedAt = dismissedAt
            self.resolvedAt = resolvedAt
        }
    }

    public private(set) var entries: [String: Entry]

    /// Bounds on what is kept, so the ledger never grows without limit.
    public static let maximumEntries = 500
    /// A resolved alert's dismissal is forgotten after this long.
    public static let resolvedRetention: TimeInterval = 30 * 86_400
    /// A dismissal nothing can confirm or clear (its repository is no longer
    /// monitored) is forgotten after this long.
    public static let unobservedRetention: TimeInterval = 90 * 86_400

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Dismissed and not since cleared.
    public func isDismissed(_ id: String) -> Bool {
        guard let entry = entries[id] else { return false }
        return entry.resolvedAt == nil
    }

    public mutating func dismiss(_ id: String, at now: Date = .now) {
        guard !id.isEmpty else { return }
        entries[id] = Entry(dismissedAt: now)
        trim()
    }

    /// "Clear all": dismisses every alert shown now. Alerts that arrive later
    /// are new and still alert.
    public mutating func dismiss<S: Sequence>(all ids: S, at now: Date = .now) where S.Element == String {
        for id in ids where !id.isEmpty { entries[id] = Entry(dismissedAt: now) }
        trim()
    }

    /// The alerts that still deserve the badge.
    public func outstanding(_ alerts: [GitHubAttention]) -> [GitHubAttention] {
        alerts.filter { !isDismissed($0.alertID) }
    }

    /// The alerts the owner dismissed that GitHub still reports.
    public func dismissed(_ alerts: [GitHubAttention]) -> [GitHubAttention] {
        alerts.filter { isDismissed($0.alertID) }
    }

    /// Lines the ledger up with what GitHub reports now.
    ///
    /// - Parameters:
    ///   - present: ids of every alert in the latest data.
    ///   - isObservable: whether the latest data could have shown this id
    ///     (its repository loaded, its kind tracked). Only then does an
    ///     absence mean "cleared"; a failed fetch never clears anything.
    /// - Returns: whether anything changed, so callers save only then.
    @discardableResult
    public mutating func reconcile(
        present: Set<String>,
        isObservable: (String) -> Bool,
        now: Date = .now
    ) -> Bool {
        let before = entries
        for (id, entry) in entries {
            if present.contains(id) {
                // Cleared once, now back: a new occurrence, so it alerts.
                if entry.resolvedAt != nil { entries.removeValue(forKey: id) }
            } else if entry.resolvedAt == nil, isObservable(id) {
                entries[id]?.resolvedAt = now
            }
        }
        entries = entries.filter { _, entry in
            if let resolvedAt = entry.resolvedAt {
                return now.timeIntervalSince(resolvedAt) < Self.resolvedRetention
            }
            return now.timeIntervalSince(entry.dismissedAt) < Self.unobservedRetention
        }
        trim()
        return entries != before
    }

    private mutating func trim() {
        guard entries.count > Self.maximumEntries else { return }
        let keep = entries.sorted { lhs, rhs in
            if lhs.value.dismissedAt != rhs.value.dismissedAt { return lhs.value.dismissedAt > rhs.value.dismissedAt }
            return lhs.key < rhs.key
        }.prefix(Self.maximumEntries)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case entries }

    /// Lenient: a damaged entry is dropped, never the whole ledger.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decode([String: LossyEntry].self, forKey: .entries)) ?? [:]
        entries = raw.compactMapValues(\.entry)
        trim()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    private struct LossyEntry: Decodable {
        var entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }
}

// MARK: - Badge

/// The single GitHub status mark: a small badge on the GitHub icon, red for
/// a failed workflow, amber for something waiting on the owner, absent when
/// every alert is dismissed or nothing is outstanding.
public enum GitHubBadge: String, Equatable, Sendable {
    case failure
    case attention

    public static func from(_ indicator: GitHubIndicator) -> GitHubBadge? {
        switch indicator {
        case .failed: .failure
        case .attention: .attention
        case .unavailable, .idle, .activity, .running: nil
        }
    }
}
