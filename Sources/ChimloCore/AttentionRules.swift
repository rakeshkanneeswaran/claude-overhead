import Foundation

/// Announces a value crossing a threshold once per crossing. Dropping back
/// below re-arms it, so a session compacted under the threshold warns again
/// the next time it fills up, but a value hovering above it never repeats.
public struct ThresholdCrossingTracker: Sendable, Equatable {
    private var above: Set<String> = []

    public init() {}

    /// Returns true when `key` has just crossed `threshold` upward.
    public mutating func crossed(_ key: String, value: Double, threshold: Double) -> Bool {
        guard value.isFinite else { return false }
        if value < threshold {
            above.remove(key)
            return false
        }
        return above.insert(key).inserted
    }

    public mutating func forget(_ key: String) {
        above.remove(key)
    }
}

/// Keyboard navigation through a list that can change between presses.
public enum SelectionCycle {
    /// The id `offset` steps from `current`, wrapping at both ends. With no
    /// current selection (or one no longer listed), forward starts at the
    /// first item and backward at the last.
    public static func next(in ids: [String], current: String?, offset: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return offset >= 0 ? ids.first : ids.last
        }
        let count = ids.count
        let step = ((offset % count) + count) % count
        return ids[(index + step) % count]
    }
}

/// One session can have a transcript in two project folders when it was
/// moved between projects. The most recently written file is the live one.
public enum TranscriptSourcePreference {
    public struct Source: Equatable, Sendable {
        public let path: String
        public let modifiedAt: Date

        public init(path: String, modifiedAt: Date) {
            self.path = path
            self.modifiedAt = modifiedAt
        }
    }

    public static func shouldReplace(_ current: Source?, with candidate: Source) -> Bool {
        guard let current else { return true }
        return current.path == candidate.path || candidate.modifiedAt >= current.modifiedAt
    }
}

/// The coarse state of a session in the notch, as history stores it.
public enum SessionActivityState: Sendable {
    case working, waitingForPermission, waitingForAnswer, finished, failed, idle

    public var historyStatus: HistoryStatus {
        switch self {
        case .working: .running
        case .waitingForPermission, .waitingForAnswer: .waiting
        case .finished: .completed
        case .failed: .failed
        // Idle says nothing new; `.unknown` never overrides a known status.
        case .idle: .unknown
        }
    }
}

extension GitHubEvent {
    /// The notification kind for this change, or nil for changes Overhead
    /// does not announce (a PR closed without merging).
    public var overheadKind: OverheadEventKind? {
        switch self {
        case .reviewRequested: .githubReviewRequested
        case .changesRequested: .githubChangesRequested
        case .approved: .githubApproved
        case .newComments: .githubNewComments
        case .ciFailed: .githubCIFailed
        case .ciPassed: .githubCIPassed
        case .merged: .githubMerged
        case .mergeConflict: .githubMergeConflict
        case .closed: nil
        }
    }
}
