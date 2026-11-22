import Foundation

/// One changed file. A named struct rather than a tuple so receipts stay
/// `Equatable` and can be diffed in tests and SwiftUI.
public struct ReceiptFileChange: Equatable, Sendable, Hashable {
    public var path: String
    /// Nil when the count is unknown (binary file, or no git data).
    public var added: Int?
    public var removed: Int?

    public init(path: String, added: Int? = nil, removed: Int? = nil) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

public struct ReceiptCommit: Equatable, Sendable, Hashable {
    public var sha: String
    public var subject: String

    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }
}

/// Git facts gathered by the caller for the session's span. Kept as plain
/// values so the receipt does not depend on how git was queried.
public struct ReceiptGitInput: Equatable, Sendable {
    public var branch: String?
    public var files: [ReceiptFileChange]
    public var commits: [ReceiptCommit]
    public var insertions: Int
    public var deletions: Int

    public init(
        branch: String? = nil,
        files: [ReceiptFileChange] = [],
        commits: [ReceiptCommit] = [],
        insertions: Int = 0,
        deletions: Int = 0
    ) {
        self.branch = branch
        self.files = files
        self.commits = commits
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// A factual, shareable summary of one session.
public struct SessionReceipt: Equatable, Sendable {
    public static let requestPreviewLength = 280
    public static let summaryPreviewLength = 400
    /// Long file lists are truncated in `shareText` to keep it pasteable.
    public static let shareTextFileLimit = 20

    public let title: String
    public let projectName: String
    public let status: HistoryStatus
    /// The latest user prompt preview, capped at `requestPreviewLength`.
    public let request: String?
    /// The latest agent response preview, capped at `summaryPreviewLength`.
    public let summary: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let duration: TimeInterval?
    public let model: String?
    public let branch: String?
    public let files: [ReceiptFileChange]
    public let insertions: Int?
    public let deletions: Int?
    public let commits: [ReceiptCommit]
    public let tests: [HistoryTestRun]
    public let agents: [HistoryAgent]
    public let pullRequests: [HistoryPullRequest]
    public let costUSD: Double?
    /// Whether file and line facts came from git rather than session metadata.
    public let usesGit: Bool

    public init(
        title: String,
        projectName: String,
        status: HistoryStatus,
        request: String?,
        summary: String?,
        startedAt: Date,
        endedAt: Date?,
        duration: TimeInterval?,
        model: String?,
        branch: String?,
        files: [ReceiptFileChange],
        insertions: Int?,
        deletions: Int?,
        commits: [ReceiptCommit],
        tests: [HistoryTestRun],
        agents: [HistoryAgent],
        pullRequests: [HistoryPullRequest],
        costUSD: Double?,
        usesGit: Bool
    ) {
        self.title = title
        self.projectName = projectName
        self.status = status
        self.request = request
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.model = model
        self.branch = branch
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
        self.commits = commits
        self.tests = tests
        self.agents = agents
        self.pullRequests = pullRequests
        self.costUSD = costUSD
        self.usesGit = usesGit
    }

    /// Plain text for pasting into chat, a PR or a standup note. ASCII
    /// punctuation and a fixed duration format keep it identical everywhere.
    /// Request and summary appear only when previews exist; cost is left out
    /// because a shared note is often read by people it does not concern.
    public var shareText: String {
        var lines: [String] = [title.isEmpty ? "Untitled session" : title]
        lines.append("\(projectName.isEmpty ? "Unknown project" : projectName) - \(status.displayName)")
        if let duration { lines.append("Duration: \(HistoryFormatting.duration(duration))") }
        if let model {
            lines.append("Model: \(ModelDisplayName.resolve(modelID: model, agent: .claude) ?? model)")
        }
        if let branch { lines.append("Branch: \(branch)") }
        if let request { lines.append("Request: \(request)") }
        if let summary { lines.append("Summary: \(summary)") }

        if let changes = changesLine { lines.append(changes) }
        for file in files.prefix(Self.shareTextFileLimit) {
            lines.append("  \(file.path)\(HistoryFormatting.lineCounts(added: file.added, removed: file.removed).map { " \($0)" } ?? "")")
        }
        if files.count > Self.shareTextFileLimit {
            lines.append("  ...and \(files.count - Self.shareTextFileLimit) more")
        }

        if !commits.isEmpty {
            lines.append("Commits:")
            lines.append(contentsOf: commits.map { "  \(String($0.sha.prefix(7))) \($0.subject)" })
        }
        if !tests.isEmpty {
            lines.append("Tests:")
            lines.append(contentsOf: tests.map { "  \($0.command): \($0.outcome)" })
        }
        if !agents.isEmpty {
            lines.append("Agents:")
            lines.append(contentsOf: agents.map(Self.agentLine))
        }
        if !pullRequests.isEmpty {
            lines.append("Pull requests:")
            lines.append(contentsOf: pullRequests.map { "  \($0.repository) #\($0.number) \($0.url)" })
        }
        return lines.joined(separator: "\n")
    }

    private var changesLine: String? {
        let counts = HistoryFormatting.lineCounts(added: insertions, removed: deletions)
        guard !files.isEmpty || counts != nil else { return nil }
        var parts: [String] = []
        if !files.isEmpty { parts.append(HistoryFormatting.count(files.count, "file")) }
        if let counts { parts.append(counts) }
        return "Changes: \(parts.joined(separator: ", "))"
    }

    private static func agentLine(_ agent: HistoryAgent) -> String {
        let name = agent.type ?? "Agent"
        let description = agent.description.map { ": \($0)" } ?? ""
        return "  \(name)\(description)\(agent.failed ? " (failed)" : "")"
    }
}

public enum SessionReceiptBuilder {
    /// Git facts win when provided because they reflect what actually landed
    /// in the working tree; otherwise the session's own counters are used and
    /// per-file counts stay unknown rather than guessed.
    public static func build(record: SessionHistoryRecord, git: ReceiptGitInput?) -> SessionReceipt {
        let files: [ReceiptFileChange]
        let insertions: Int?
        let deletions: Int?
        if let git {
            files = git.files
            insertions = git.insertions
            deletions = git.deletions
        } else {
            files = record.filesChanged.map { ReceiptFileChange(path: $0) }
            insertions = record.linesAdded
            deletions = record.linesRemoved
        }

        return SessionReceipt(
            title: record.title,
            projectName: record.projectName,
            status: record.status,
            request: HistoryFormatting.preview(record.latestUserPrompt, limit: SessionReceipt.requestPreviewLength),
            summary: HistoryFormatting.preview(record.latestAgentResponse, limit: SessionReceipt.summaryPreviewLength),
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            duration: record.duration,
            model: record.model,
            branch: HistoryMerge.preferred(git?.branch, record.gitBranch),
            files: files,
            insertions: insertions,
            deletions: deletions,
            commits: git?.commits ?? [],
            tests: record.tests,
            agents: record.agents,
            pullRequests: record.pullRequests,
            costUSD: record.costUSD,
            usesGit: git != nil
        )
    }
}

/// Locale-independent formatting shared by receipts and recaps, so shared
/// text and tests read the same on every machine.
enum HistoryFormatting {
    /// Collapses whitespace runs to single spaces and caps the length,
    /// counting the trailing ellipsis within the limit.
    static func preview(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(0, limit - 1))) + "\u{2026}"
    }

    /// `38s`, `4m 12s`, `1h 05m`.
    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        if minutes > 0 { return "\(minutes)m \(String(format: "%02d", seconds))s" }
        return "\(seconds)s"
    }

    static func lineCounts(added: Int?, removed: Int?) -> String? {
        switch (added, removed) {
        case let (added?, removed?): "+\(added) / -\(removed)"
        case let (added?, nil): "+\(added)"
        case let (nil, removed?): "-\(removed)"
        case (nil, nil): nil
        }
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// `String(format:)` without a locale always uses "." as the separator.
    static func currency(_ value: Double) -> String {
        "$" + String(format: "%.2f", value)
    }
}
