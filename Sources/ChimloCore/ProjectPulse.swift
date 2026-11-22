import Foundation

/// A per-project summary: what is running, what needs the owner, and what
/// recently finished.
public struct ProjectPulse: Equatable, Sendable, Identifiable {
    public var id: String { projectKey }
    /// The project path, or the project name when no path is known.
    public let projectKey: String
    public let name: String
    public let path: String?
    /// Branch of the most recently active session that reported one.
    public let branch: String?
    /// Newest activity first.
    public let activeSessionIDs: [String]
    /// Newest activity first.
    public let attentionSessionIDs: [String]
    public let recentCompleted: [SessionHistoryRecord]
    public let recentFailed: [SessionHistoryRecord]
    public let lastActivityAt: Date?
    public let linkedPullRequests: [HistoryPullRequest]

    public init(
        projectKey: String,
        name: String,
        path: String?,
        branch: String?,
        activeSessionIDs: [String],
        attentionSessionIDs: [String],
        recentCompleted: [SessionHistoryRecord],
        recentFailed: [SessionHistoryRecord],
        lastActivityAt: Date?,
        linkedPullRequests: [HistoryPullRequest]
    ) {
        self.projectKey = projectKey
        self.name = name
        self.path = path
        self.branch = branch
        self.activeSessionIDs = activeSessionIDs
        self.attentionSessionIDs = attentionSessionIDs
        self.recentCompleted = recentCompleted
        self.recentFailed = recentFailed
        self.lastActivityAt = lastActivityAt
        self.linkedPullRequests = linkedPullRequests
    }
}

public enum ProjectPulseBuilder {
    /// The grouping key used by pulses and timelines. Paths are compared
    /// without trailing slashes so `/repo` and `/repo/` are one project.
    public static func projectKey(for record: SessionHistoryRecord) -> String {
        if let path = record.projectPath, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return HistorySearch.normalizedPath(path)
        }
        return record.projectName
    }

    /// Liveness comes from the caller's sets, not from `status`: a record can
    /// say `running` long after its process died, while the live set is
    /// authoritative. Sorted so projects needing the owner come first, then
    /// projects with running work, then by recency.
    public static func build(
        records: [SessionHistoryRecord],
        liveSessionIDs: Set<String>,
        attentionSessionIDs: Set<String>,
        recentLimit: Int = 5
    ) -> [ProjectPulse] {
        let limit = max(0, recentLimit)
        let groups = Dictionary(grouping: records, by: projectKey(for:))

        let pulses = groups.map { key, group -> ProjectPulse in
            let newestFirst = group.sorted(by: SessionHistoryOrdering.newestFirst)
            let pathFallbackName = newestFirst.first?.projectPath.map(HistorySearch.lastPathComponent(of:))
            let name = newestFirst.lazy.map(\.projectName).first { !$0.isEmpty } ?? pathFallbackName ?? key
            let pullRequests = HistoryMerge.union(
                newestFirst.flatMap(\.pullRequests),
                key: { "\($0.repository)#\($0.number)" },
                merge: { old, _ in old }
            )
            return ProjectPulse(
                projectKey: key,
                name: name,
                path: newestFirst.lazy.compactMap(\.projectPath).first,
                branch: newestFirst.lazy.compactMap(\.gitBranch).first,
                activeSessionIDs: newestFirst.filter { liveSessionIDs.contains($0.id) }.map(\.id),
                attentionSessionIDs: newestFirst.filter { attentionSessionIDs.contains($0.id) }.map(\.id),
                recentCompleted: Array(newestFirst.filter { $0.status == .completed }.prefix(limit)),
                recentFailed: Array(newestFirst.filter { $0.status == .failed }.prefix(limit)),
                lastActivityAt: newestFirst.first?.lastActivityAt,
                linkedPullRequests: pullRequests
            )
        }

        return pulses.sorted { lhs, rhs in
            let lhsAttention = !lhs.attentionSessionIDs.isEmpty
            let rhsAttention = !rhs.attentionSessionIDs.isEmpty
            if lhsAttention != rhsAttention { return lhsAttention }
            let lhsActive = !lhs.activeSessionIDs.isEmpty
            let rhsActive = !rhs.activeSessionIDs.isEmpty
            if lhsActive != rhsActive { return lhsActive }
            let lhsDate = lhs.lastActivityAt ?? .distantPast
            let rhsDate = rhs.lastActivityAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.projectKey < rhs.projectKey
        }
    }
}

/// One line in a project's history timeline.
public struct ProjectTimelineEntry: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable, Hashable, CaseIterable {
        case sessionStarted, sessionCompleted, sessionFailed, branchChanged, pullRequestLinked, compacted

        /// Causal order for entries at the same instant: a branch switch
        /// precedes the session it was seen in, which precedes its outcome.
        var causalRank: Int {
            switch self {
            case .branchChanged: 0
            case .sessionStarted: 1
            case .compacted: 2
            case .pullRequestLinked: 3
            case .sessionCompleted, .sessionFailed: 4
            }
        }
    }

    public let id: String
    public let at: Date
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let sessionID: String

    public init(id: String, at: Date, kind: Kind, title: String, detail: String?, sessionID: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sessionID = sessionID
    }
}

public enum ProjectTimelineBuilder {
    /// Entries for one project (`projectKey` as produced by
    /// `ProjectPulseBuilder.projectKey(for:)`), newest first, with inclusive
    /// date bounds.
    ///
    /// Pull requests carry no timestamp of their own, so they are placed at the
    /// session's end (or last activity). A branch change is reported when a
    /// session's branch differs from the previous session (by start time) that
    /// reported one; sessions without a branch neither trigger nor reset it.
    /// Interrupted sessions get a start entry but no outcome entry, because an
    /// interruption is not a result.
    public static func entries(
        records: [SessionHistoryRecord],
        projectKey: String,
        from: Date? = nil,
        to: Date? = nil
    ) -> [ProjectTimelineEntry] {
        let sessions = records
            .filter { ProjectPulseBuilder.projectKey(for: $0) == projectKey }
            .sorted { lhs, rhs in
                lhs.startedAt != rhs.startedAt ? lhs.startedAt < rhs.startedAt : lhs.id < rhs.id
            }

        var entries: [ProjectTimelineEntry] = []
        var previousBranch: String?
        for session in sessions {
            let finishedAt = session.endedAt ?? session.lastActivityAt

            if let branch = session.gitBranch, !branch.isEmpty {
                if let previousBranch, previousBranch != branch {
                    entries.append(ProjectTimelineEntry(
                        id: "\(session.id):branchChanged",
                        at: session.startedAt,
                        kind: .branchChanged,
                        title: "Switched to \(branch)",
                        detail: "from \(previousBranch)",
                        sessionID: session.id
                    ))
                }
                previousBranch = branch
            }

            entries.append(ProjectTimelineEntry(
                id: "\(session.id):sessionStarted",
                at: session.startedAt,
                kind: .sessionStarted,
                title: session.title.isEmpty ? "Session started" : session.title,
                detail: session.gitBranch,
                sessionID: session.id
            ))

            for event in session.events where event.kind == .compacted {
                entries.append(ProjectTimelineEntry(
                    id: "\(session.id):compacted:\(event.at.timeIntervalSinceReferenceDate)",
                    at: event.at,
                    kind: .compacted,
                    title: "Context compacted",
                    detail: event.detail,
                    sessionID: session.id
                ))
            }

            for pullRequest in session.pullRequests {
                entries.append(ProjectTimelineEntry(
                    id: "\(session.id):pullRequest:\(pullRequest.repository)#\(pullRequest.number)",
                    at: finishedAt,
                    kind: .pullRequestLinked,
                    title: "Linked \(pullRequest.repository) #\(pullRequest.number)",
                    detail: pullRequest.url.isEmpty ? nil : pullRequest.url,
                    sessionID: session.id
                ))
            }

            switch session.status {
            case .completed:
                entries.append(outcome(.sessionCompleted, "Completed", session, at: finishedAt))
            case .failed:
                entries.append(outcome(.sessionFailed, "Failed", session, at: finishedAt))
            case .running, .waiting, .interrupted, .unknown:
                break
            }
        }

        return entries
            .filter { entry in
                if let from, entry.at < from { return false }
                if let to, entry.at > to { return false }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.at != rhs.at { return lhs.at > rhs.at }
                if lhs.kind.causalRank != rhs.kind.causalRank { return lhs.kind.causalRank > rhs.kind.causalRank }
                return lhs.id < rhs.id
            }
    }

    private static func outcome(
        _ kind: ProjectTimelineEntry.Kind,
        _ verb: String,
        _ session: SessionHistoryRecord,
        at: Date
    ) -> ProjectTimelineEntry {
        let duration = session.duration.map { " in \(HistoryFormatting.duration($0))" } ?? ""
        return ProjectTimelineEntry(
            id: "\(session.id):\(kind.rawValue)",
            at: at,
            kind: kind,
            title: "\(verb)\(duration)",
            detail: session.title.isEmpty ? nil : session.title,
            sessionID: session.id
        )
    }
}
