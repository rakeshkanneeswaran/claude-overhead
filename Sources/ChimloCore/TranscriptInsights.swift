import Foundation

/// A coarse bucket for what Claude is doing right now. The notch has room for
/// a few words, so tool names collapse into the handful of activities an owner
/// actually cares about at a glance.
public enum ToolActivityKind: String, Codable, Sendable, CaseIterable {
    case reading
    case searching
    case writing
    case executing
    case delegating
    case asking
    case browsing
    case other

    public init(toolName: String) {
        switch toolName {
        case "Read", "NotebookRead":
            self = .reading
        case "Glob", "Grep", "LS", "ToolSearch":
            self = .searching
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            self = .writing
        case "Bash", "BashOutput", "KillShell":
            self = .executing
        case "Agent", "Task":
            self = .delegating
        case "AskUserQuestion":
            self = .asking
        case "WebFetch", "WebSearch":
            self = .browsing
        default:
            // MCP tools and future built-ins stay visible as generic work
            // rather than being guessed into a misleading bucket.
            self = .other
        }
    }

    public var label: String {
        switch self {
        case .reading: "Reading files"
        case .searching: "Searching"
        case .writing: "Writing files"
        case .executing: "Running a command"
        case .delegating: "Delegating to agents"
        case .asking: "Asking you"
        case .browsing: "Browsing the web"
        case .other: "Working"
        }
    }
}

/// The latest main-chain tool call. Tool inputs are deliberately not kept:
/// the name is enough to say what kind of work is happening.
public struct ToolActivity: Codable, Equatable, Sendable {
    public let kind: ToolActivityKind
    public let toolName: String
    public let startedAt: Date?

    public init(kind: ToolActivityKind, toolName: String, startedAt: Date?) {
        self.kind = kind
        self.toolName = toolName
        self.startedAt = startedAt
    }

    public init(toolName: String, startedAt: Date?) {
        self.init(kind: ToolActivityKind(toolName: toolName), toolName: toolName, startedAt: startedAt)
    }
}

/// How close the context window is to triggering compaction. Thresholds are
/// parameters so the app can tune them without touching the scanner.
public enum ContextHealth: String, Codable, Sendable {
    case healthy
    case attention
    case critical

    public static func classify(
        fraction: Double,
        attentionAt: Double = 0.7,
        criticalAt: Double = 0.9
    ) -> ContextHealth {
        // NaN compares false against everything; treat unknown as healthy
        // instead of raising a false alarm.
        guard !fraction.isNaN else { return .healthy }
        if fraction >= criticalAt { return .critical }
        if fraction >= attentionAt { return .attention }
        return .healthy
    }
}

/// One `compact_boundary` marker. Counts are kept so the UI can show how much
/// a compaction reclaimed; the summary text itself is never read.
public struct CompactionEvent: Codable, Equatable, Sendable {
    public let at: Date?
    public let trigger: String?
    public let preTokens: Int?
    public let postTokens: Int?

    public init(at: Date?, trigger: String?, preTokens: Int?, postTokens: Int?) {
        self.at = at
        self.trigger = trigger
        self.preTokens = preTokens
        self.postTokens = postTokens
    }
}

/// Cumulative prompt-cache usage over main-chain assistant messages. Claude
/// Code writes one transcript line per streamed content block, each repeating
/// the message's usage, so totals are counted once per `message.id`.
public struct CacheStats: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var outputTokens: Int

    public init(
        inputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        outputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.outputTokens = outputTokens
    }

    /// The share of prompt tokens served from cache. `nil` until any prompt
    /// tokens exist, so a fresh session does not read as a 0% hit rate.
    public var hitRatio: Double? {
        let denominator = inputTokens + cacheReadTokens + cacheCreationTokens
        guard denominator > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denominator)
    }
}

/// A subagent launched through the Agent (formerly Task) tool. Completion is
/// the matching `tool_result`; the subagent's own prompt is never kept.
public struct AgentRun: Codable, Equatable, Sendable, Identifiable {
    /// The launching `tool_use` id, which the `tool_result` echoes back.
    public let id: String
    public var description: String?
    public var subagentType: String?
    public var model: String?
    public var runsInBackground: Bool
    public var startedAt: Date?
    public var finishedAt: Date?
    public var failed: Bool

    public init(
        id: String,
        description: String? = nil,
        subagentType: String? = nil,
        model: String? = nil,
        runsInBackground: Bool = false,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        failed: Bool = false
    ) {
        self.id = id
        self.description = description
        self.subagentType = subagentType
        self.model = model
        self.runsInBackground = runsInBackground
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failed = failed
    }

    public var isRunning: Bool { finishedAt == nil }
}

public struct LinkedPullRequest: Codable, Equatable, Sendable, Hashable {
    public let number: Int
    public let url: String
    public let repository: String

    public init(number: Int, url: String, repository: String) {
        self.number = number
        self.url = url
        self.repository = repository
    }
}

/// Totals from the latest `cost-state` line. Claude Code rewrites the running
/// totals each time, so the newest line supersedes every earlier one.
public struct SessionCost: Codable, Equatable, Sendable {
    public let totalUSD: Double?
    public let linesAdded: Int?
    public let linesRemoved: Int?
    public let durationMs: Int?
    public let apiDurationMs: Int?

    public init(
        totalUSD: Double?,
        linesAdded: Int?,
        linesRemoved: Int?,
        durationMs: Int?,
        apiDurationMs: Int?
    ) {
        self.totalUSD = totalUSD
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.durationMs = durationMs
        self.apiDurationMs = apiDurationMs
    }
}

public enum TestOutcome: String, Codable, Sendable {
    case passed
    case failed
    case unknown
}

/// A Bash call that ran a test suite. `command` is only the test-runner part
/// of the shell line, with leading environment assignments removed (they are
/// where tokens and secrets usually live) and capped at 160 characters.
public struct TestRun: Codable, Equatable, Sendable {
    public let command: String
    public let startedAt: Date?
    public var outcome: TestOutcome

    public init(command: String, startedAt: Date?, outcome: TestOutcome = .unknown) {
        self.command = command
        self.startedAt = startedAt
        self.outcome = outcome
    }
}

/// Privacy-safe facts derived from one Claude Code transcript. No prompt,
/// response, or tool-output text is retained; the only free text is file
/// paths from editing tools, redacted test commands, and short agent
/// descriptions.
public struct TranscriptInsights: Codable, Equatable, Sendable {
    /// Latest main-chain assistant model.
    public var model: String?
    /// Latest main-chain prompt size: input + cache read + cache creation,
    /// which is what occupies the context window.
    public var contextTokens: Int?
    public var contextWindowTokens: Int?
    /// `contextTokens / contextWindowTokens`, clamped to 0...1.
    public var contextFraction: Double?
    public var compactions: [CompactionEvent]
    public var cache: CacheStats
    /// Latest main-chain tool call; `nil` once the turn ends or is interrupted.
    public var activity: ToolActivity?
    public var agents: [AgentRun]
    public var gitBranch: String?
    public var pullRequests: [LinkedPullRequest]
    public var cost: SessionCost?
    /// Unique paths from editing tools in first-seen order, capped at 200.
    public var filesTouched: [String]
    /// Newest last, capped at 50.
    public var testRuns: [TestRun]
    public var lastUpdated: Date?

    public init(
        model: String? = nil,
        contextTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        contextFraction: Double? = nil,
        compactions: [CompactionEvent] = [],
        cache: CacheStats = CacheStats(),
        activity: ToolActivity? = nil,
        agents: [AgentRun] = [],
        gitBranch: String? = nil,
        pullRequests: [LinkedPullRequest] = [],
        cost: SessionCost? = nil,
        filesTouched: [String] = [],
        testRuns: [TestRun] = [],
        lastUpdated: Date? = nil
    ) {
        self.model = model
        self.contextTokens = contextTokens
        self.contextWindowTokens = contextWindowTokens
        self.contextFraction = contextFraction
        self.compactions = compactions
        self.cache = cache
        self.activity = activity
        self.agents = agents
        self.gitBranch = gitBranch
        self.pullRequests = pullRequests
        self.cost = cost
        self.filesTouched = filesTouched
        self.testRuns = testRuns
        self.lastUpdated = lastUpdated
    }

    public static let empty = TranscriptInsights()

    /// Health of the current context usage with default thresholds, or `nil`
    /// while the fraction is unknown.
    public var contextHealth: ContextHealth? {
        contextFraction.map { ContextHealth.classify(fraction: $0) }
    }

    /// Subagents whose launching tool call has not returned yet.
    public var runningAgents: [AgentRun] {
        agents.filter(\.isRunning)
    }
}

/// Context window sizes by model id. The transcript records the API model id,
/// which carries no context-size hint, so this stays a small, conservative
/// lookup rather than a pricing table that goes stale.
public enum ContextWindow {
    public static let standardTokens = 200_000
    public static let extendedTokens = 1_000_000

    public static func size(forModel model: String?) -> Int? {
        guard let model else { return nil }
        let normalized = model.lowercased()
        if normalized.contains("[1m]") || normalized.contains("-1m") {
            return extendedTokens
        }
        if normalized.contains("claude") {
            return standardTokens
        }
        return nil
    }

    /// Like `size(forModel:)`, but trusts observed usage over the model id.
    /// The 1M window is enabled by a request header, not the model id, so a
    /// prompt larger than 200K can only mean the extended window is active;
    /// without this the gauge would sit pinned at 100%.
    public static func size(forModel model: String?, observedTokens: Int?) -> Int? {
        guard let base = size(forModel: model) else { return nil }
        if let observedTokens, observedTokens > base, observedTokens <= extendedTokens {
            return extendedTokens
        }
        return base
    }
}
