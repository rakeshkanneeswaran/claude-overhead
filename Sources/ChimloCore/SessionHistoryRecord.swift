import Foundation

/// Lifecycle state of a remembered session. History outlives the live session
/// list, so this is a durable summary rather than the reducer's live phase.
public enum HistoryStatus: String, Codable, Sendable, CaseIterable {
    case running, waiting, completed, failed, interrupted, unknown

    /// In-flight sessions are never pruned and sort as "active" in summaries.
    public var isActive: Bool { self == .running || self == .waiting }

    public var displayName: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .unknown: "Unknown"
        }
    }

    /// A status added by a newer build must not make the whole history file
    /// unreadable for an older one, so unrecognised values decode as `.unknown`.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HistoryStatus(rawValue: raw) ?? .unknown
    }
}

/// A subagent (Task tool) invocation observed during a session.
public struct HistoryAgent: Codable, Equatable, Sendable, Hashable {
    public let id: String
    public var type: String?
    public var description: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var failed: Bool

    public init(
        id: String,
        type: String? = nil,
        description: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        failed: Bool = false
    ) {
        self.id = id
        self.type = type
        self.description = description
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failed = failed
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, description, startedAt, finishedAt, failed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }

    /// The same agent reported twice must converge: newer details win, the
    /// window only widens, and a failure is sticky because a later snapshot
    /// that omits it is less informed, not a recovery.
    func merged(with newer: HistoryAgent) -> HistoryAgent {
        HistoryAgent(
            id: id,
            type: HistoryMerge.preferred(newer.type, type),
            description: HistoryMerge.preferred(newer.description, description),
            startedAt: HistoryMerge.earliest(startedAt, newer.startedAt),
            finishedAt: HistoryMerge.latest(finishedAt, newer.finishedAt),
            failed: failed || newer.failed
        )
    }
}

/// A test command the session ran and how it ended.
public struct HistoryTestRun: Codable, Equatable, Sendable, Hashable {
    public static let passed = "passed"
    public static let failed = "failed"
    public static let unknown = "unknown"

    public let command: String
    /// `passed`, `failed` or `unknown`. A string so new outcomes stay decodable.
    public var outcome: String

    public init(command: String, outcome: String = HistoryTestRun.unknown) {
        self.command = command
        self.outcome = outcome
    }

    /// Re-running the same command replaces its outcome, except that an
    /// `unknown` (still running, or not parsed) never hides a known result.
    func merged(with newer: HistoryTestRun) -> HistoryTestRun {
        let newerIsInformative = newer.outcome != HistoryTestRun.unknown && !newer.outcome.isEmpty
        return HistoryTestRun(command: command, outcome: newerIsInformative ? newer.outcome : outcome)
    }
}

/// A pull request the session created or referenced.
public struct HistoryPullRequest: Codable, Equatable, Sendable, Hashable {
    public let number: Int
    public let url: String
    /// `owner/name`, used with `number` as the identity.
    public let repository: String

    public init(number: Int, url: String, repository: String) {
        self.number = number
        self.url = url
        self.repository = repository
    }
}

public enum HistoryEventKind: String, Codable, Sendable {
    case started, prompt, completed, failed, permission, question, compacted, agentStarted, agentFinished
}

/// A coarse milestone in a session. Deliberately small: history is a summary,
/// and Claude's own transcript remains the source of the full conversation.
public struct HistoryEvent: Codable, Equatable, Sendable, Hashable {
    public let kind: HistoryEventKind
    public let at: Date
    public var detail: String?

    public init(kind: HistoryEventKind, at: Date, detail: String? = nil) {
        self.kind = kind
        self.at = at
        self.detail = detail
    }
}

/// One remembered Claude session. Records are built from snapshots that may
/// arrive repeatedly and out of order, so `merged(with:)` is the only way the
/// store combines them and is designed to be idempotent.
public struct SessionHistoryRecord: Codable, Equatable, Sendable, Identifiable {
    /// Keeps a chatty session from growing its record without bound.
    public static let maxEvents = 200

    /// Claude session id.
    public let id: String
    public var projectPath: String?
    public var projectName: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var lastActivityAt: Date
    public var model: String?
    public var status: HistoryStatus
    public var gitBranch: String?
    /// Preview only. The store drops it when previews are disabled.
    public var latestUserPrompt: String?
    /// Preview only. The store drops it when previews are disabled.
    public var latestAgentResponse: String?
    /// A reference to Claude's own transcript. History never copies its contents.
    public var transcriptPath: String?
    public var costUSD: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var filesChanged: [String]
    public var agents: [HistoryAgent]
    public var tests: [HistoryTestRun]
    public var pullRequests: [HistoryPullRequest]
    /// Oldest first, unique per (kind, at), at most `maxEvents` once merged.
    public var events: [HistoryEvent]
    public var contextPeakFraction: Double?

    /// Wall time from start to end (or to the latest activity while running).
    /// Nil when clocks disagree and the result would be negative.
    public var duration: TimeInterval? {
        let interval = (endedAt ?? lastActivityAt).timeIntervalSince(startedAt)
        return interval >= 0 ? interval : nil
    }

    public init(
        id: String,
        projectPath: String?,
        projectName: String,
        title: String,
        startedAt: Date,
        lastActivityAt: Date,
        status: HistoryStatus,
        endedAt: Date? = nil,
        model: String? = nil,
        gitBranch: String? = nil,
        latestUserPrompt: String? = nil,
        latestAgentResponse: String? = nil,
        transcriptPath: String? = nil,
        costUSD: Double? = nil,
        linesAdded: Int? = nil,
        linesRemoved: Int? = nil,
        filesChanged: [String] = [],
        agents: [HistoryAgent] = [],
        tests: [HistoryTestRun] = [],
        pullRequests: [HistoryPullRequest] = [],
        events: [HistoryEvent] = [],
        contextPeakFraction: Double? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.projectName = projectName
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActivityAt = lastActivityAt
        self.model = model
        self.status = status
        self.gitBranch = gitBranch
        self.latestUserPrompt = latestUserPrompt
        self.latestAgentResponse = latestAgentResponse
        self.transcriptPath = transcriptPath
        self.costUSD = costUSD
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.filesChanged = filesChanged
        self.agents = agents
        self.tests = tests
        self.pullRequests = pullRequests
        self.events = events
        self.contextPeakFraction = contextPeakFraction
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectPath, projectName, title, startedAt, endedAt, lastActivityAt
        case model, status, gitBranch, latestUserPrompt, latestAgentResponse, transcriptPath
        case costUSD, linesAdded, linesRemoved, filesChanged, agents, tests, pullRequests
        case events, contextPeakFraction
    }

    /// Only identity and the timeline anchors are required. Every collection
    /// defaults to empty so a record written before a field existed still
    /// loads, and events of a kind this build does not know are skipped
    /// instead of failing the whole history file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? startedAt
        model = try container.decodeIfPresent(String.self, forKey: .model)
        status = try container.decodeIfPresent(HistoryStatus.self, forKey: .status) ?? .unknown
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        latestUserPrompt = try container.decodeIfPresent(String.self, forKey: .latestUserPrompt)
        latestAgentResponse = try container.decodeIfPresent(String.self, forKey: .latestAgentResponse)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        linesAdded = try container.decodeIfPresent(Int.self, forKey: .linesAdded)
        linesRemoved = try container.decodeIfPresent(Int.self, forKey: .linesRemoved)
        filesChanged = try container.decodeIfPresent([String].self, forKey: .filesChanged) ?? []
        agents = try container.decodeIfPresent([HistoryAgent].self, forKey: .agents) ?? []
        tests = try container.decodeIfPresent([HistoryTestRun].self, forKey: .tests) ?? []
        pullRequests = try container.decodeIfPresent([HistoryPullRequest].self, forKey: .pullRequests) ?? []
        events = (try container.decodeIfPresent([LossyEvent].self, forKey: .events) ?? []).compactMap(\.event)
        contextPeakFraction = try container.decodeIfPresent(Double.self, forKey: .contextPeakFraction)
    }

    /// Combines this record with a newer snapshot of the same session.
    ///
    /// Idempotent by construction (`a.merged(with: b).merged(with: b)` equals
    /// `a.merged(with: b)`) because updates are re-delivered after restarts and
    /// rediscovery:
    /// - the time window only widens (earliest start, latest activity and end);
    /// - newer non-nil (and non-empty) scalars win; `.unknown` never replaces a
    ///   known status; the context peak keeps the maximum;
    /// - arrays are order-preserving unions keyed by identity (path, agent id,
    ///   test command, repository + PR number), with per-item merges;
    /// - events are unique per (kind, at), sorted, and capped to the newest
    ///   `maxEvents`, using a total order so the cap is deterministic.
    public func merged(with newer: SessionHistoryRecord) -> SessionHistoryRecord {
        var result = self
        result.projectPath = HistoryMerge.preferred(newer.projectPath, projectPath)
        result.projectName = HistoryMerge.preferred(newer.projectName, projectName) ?? projectName
        result.title = HistoryMerge.preferred(newer.title, title) ?? title
        result.startedAt = min(startedAt, newer.startedAt)
        result.endedAt = HistoryMerge.latest(endedAt, newer.endedAt)
        result.lastActivityAt = max(lastActivityAt, newer.lastActivityAt)
        result.model = HistoryMerge.preferred(newer.model, model)
        result.status = newer.status == .unknown ? status : newer.status
        result.gitBranch = HistoryMerge.preferred(newer.gitBranch, gitBranch)
        result.latestUserPrompt = HistoryMerge.preferred(newer.latestUserPrompt, latestUserPrompt)
        result.latestAgentResponse = HistoryMerge.preferred(newer.latestAgentResponse, latestAgentResponse)
        result.transcriptPath = HistoryMerge.preferred(newer.transcriptPath, transcriptPath)
        result.costUSD = newer.costUSD ?? costUSD
        result.linesAdded = newer.linesAdded ?? linesAdded
        result.linesRemoved = newer.linesRemoved ?? linesRemoved
        result.contextPeakFraction = HistoryMerge.latest(contextPeakFraction, newer.contextPeakFraction)
        result.filesChanged = HistoryMerge.union(filesChanged + newer.filesChanged, key: { $0 }, merge: { old, _ in old })
        result.agents = HistoryMerge.union(agents + newer.agents, key: \.id, merge: { $0.merged(with: $1) })
        result.tests = HistoryMerge.union(tests + newer.tests, key: \.command, merge: { $0.merged(with: $1) })
        result.pullRequests = HistoryMerge.union(
            pullRequests + newer.pullRequests,
            key: { PullRequestKey(repository: $0.repository, number: $0.number) },
            merge: { old, new in
                HistoryPullRequest(number: old.number, url: new.url.isEmpty ? old.url : new.url, repository: old.repository)
            }
        )
        result.events = Self.normalizedEvents(events + newer.events)
        return result
    }

    /// Applies the same dedupe and cap a merge would, for a record that has
    /// nothing to merge with yet.
    func normalized() -> SessionHistoryRecord {
        merged(with: self)
    }

    private static func normalizedEvents(_ events: [HistoryEvent]) -> [HistoryEvent] {
        let unique = HistoryMerge.union(
            events,
            key: { EventKey(kind: $0.kind, at: $0.at) },
            merge: { old, new in HistoryEvent(kind: old.kind, at: old.at, detail: HistoryMerge.preferred(new.detail, old.detail)) }
        )
        // Sort by a total order: with ties broken only by insertion order the
        // cap could keep a different subset on a repeated merge.
        let sorted = unique.sorted { lhs, rhs in
            lhs.at != rhs.at ? lhs.at < rhs.at : lhs.kind.rawValue < rhs.kind.rawValue
        }
        return Array(sorted.suffix(maxEvents))
    }
}

private struct PullRequestKey: Hashable {
    let repository: String
    let number: Int
}

private struct EventKey: Hashable {
    let kind: HistoryEventKind
    let at: Date
}

/// Decodes one event, or nothing when its kind is from a newer build.
private struct LossyEvent: Decodable {
    let event: HistoryEvent?

    init(from decoder: any Decoder) throws {
        event = try? HistoryEvent(from: decoder)
    }
}

/// Shared merge rules so every field follows the same precedence.
enum HistoryMerge {
    static func preferred(_ newer: String?, _ older: String?) -> String? {
        if let newer, !newer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return newer }
        return older
    }

    static func earliest<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (value?, nil), let (nil, value?): value
        case (nil, nil): nil
        }
    }

    static func latest<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (value?, nil), let (nil, value?): value
        case (nil, nil): nil
        }
    }

    /// Order-preserving dedupe: the first occurrence keeps its position and
    /// later duplicates are folded into it.
    static func union<Element, Key: Hashable>(
        _ elements: [Element],
        key: (Element) -> Key,
        merge: (Element, Element) -> Element
    ) -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(elements.count)
        var indexByKey: [Key: Int] = [:]
        for element in elements {
            let elementKey = key(element)
            if let index = indexByKey[elementKey] {
                result[index] = merge(result[index], element)
            } else {
                indexByKey[elementKey] = result.count
                result.append(element)
            }
        }
        return result
    }
}
