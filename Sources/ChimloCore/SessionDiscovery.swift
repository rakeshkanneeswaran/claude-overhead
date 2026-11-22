import Foundation

public enum SessionEvidenceSource: String, Codable, Equatable, Sendable {
    case claudeTranscript
    case process
    case cache
}

public enum SessionTitleKind: Int, Codable, Comparable, Sendable {
    case workspace
    case task

    public static func < (lhs: SessionTitleKind, rhs: SessionTitleKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The local-session vocabulary shared by transcript discovery, process
/// reconciliation, and persistence. Prompt and
/// response previews are transient: Claude Overhead's registry deliberately omits them.
public struct SessionCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let agent: AgentKind
    public var title: String
    public var titleKind: SessionTitleKind
    public var detail: String
    public var model: String?
    public var terminal: String?
    public var projectPath: String?
    public var jumpURL: URL?
    public var latestUserPrompt: String?
    public var latestAgentResponse: String?
    public var latestConversationUpdatedAt: Date?
    public var phase: SessionPhase
    public var updatedAt: Date
    public var evidence: SessionEvidenceSource

    public init(
        id: String,
        agent: AgentKind,
        title: String,
        titleKind: SessionTitleKind = .workspace,
        detail: String,
        model: String? = nil,
        terminal: String? = nil,
        projectPath: String? = nil,
        jumpURL: URL? = nil,
        latestUserPrompt: String? = nil,
        latestAgentResponse: String? = nil,
        latestConversationUpdatedAt: Date? = nil,
        phase: SessionPhase,
        updatedAt: Date,
        evidence: SessionEvidenceSource
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.titleKind = titleKind
        self.detail = detail
        self.model = model
        self.terminal = terminal
        self.projectPath = projectPath
        self.jumpURL = jumpURL
        self.latestUserPrompt = latestUserPrompt
        self.latestAgentResponse = latestAgentResponse
        self.latestConversationUpdatedAt = latestConversationUpdatedAt
        self.phase = phase
        self.updatedAt = updatedAt
        self.evidence = evidence
    }

    public func normalizedForCache() -> SessionCandidate {
        var normalized = self
        normalized.evidence = .cache
        switch normalized.phase {
        case .waitingForApproval, .waitingForAnswer:
            normalized.phase = .working
            normalized.detail = "Working"
        case .working, .completed, .failed:
            break
        }
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, title, titleKind, detail, model, terminal, projectPath
        case jumpURL, phase, updatedAt, evidence
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        agent = try values.decode(AgentKind.self, forKey: .agent)
        title = try values.decode(String.self, forKey: .title)
        titleKind = try values.decodeIfPresent(SessionTitleKind.self, forKey: .titleKind) ?? .workspace
        detail = try values.decode(String.self, forKey: .detail)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        terminal = try values.decodeIfPresent(String.self, forKey: .terminal)
        projectPath = try values.decodeIfPresent(String.self, forKey: .projectPath)
        jumpURL = try values.decodeIfPresent(URL.self, forKey: .jumpURL)
        latestUserPrompt = nil
        latestAgentResponse = nil
        latestConversationUpdatedAt = nil
        phase = try values.decode(SessionPhase.self, forKey: .phase)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        evidence = try values.decode(SessionEvidenceSource.self, forKey: .evidence)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(agent, forKey: .agent)
        try values.encode(title, forKey: .title)
        try values.encode(titleKind, forKey: .titleKind)
        try values.encode(detail, forKey: .detail)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encodeIfPresent(terminal, forKey: .terminal)
        try values.encodeIfPresent(projectPath, forKey: .projectPath)
        try values.encodeIfPresent(jumpURL, forKey: .jumpURL)
        try values.encode(phase, forKey: .phase)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(evidence, forKey: .evidence)
    }
}

/// Streams provider JSONL into a bounded local-session candidate. Only the
/// visible user prompt and agent response are read; reasoning, tools, tool
/// results, environment values, and file contents remain excluded.
public struct PrivacySafeSessionMetadataScanner: Sendable {
    private var sessionID: String?
    private var workingDirectory: String?
    private var model: String?
    private var taskTitle: String?
    private var latestUserPrompt: String?
    private var latestAgentResponse: String?
    private var latestConversationUpdatedAt: Date?
    private var phase: SessionPhase = .completed
    private var updatedAt: Date?

    public init() {}

    public mutating func consume(line data: Data) {
        guard data.count <= Self.maximumLineBytes else { return }
        consumeClaude(line: data)
    }

    public func candidate(
        transcriptPath: String,
        fallbackUpdatedAt: Date
    ) -> SessionCandidate? {
        guard let sessionID = Self.bounded(sessionID, maximumUTF8Bytes: 512),
              let workingDirectory = Self.bounded(workingDirectory, maximumUTF8Bytes: 4_096) else {
            return nil
        }

        let workspace = URL(fileURLWithPath: workingDirectory).lastPathComponent
        let safeWorkspace = workspace.isEmpty ? "Workspace" : workspace
        let title = taskTitle ?? safeWorkspace
        return SessionCandidate(
            id: sessionID,
            agent: .claude,
            title: title,
            titleKind: taskTitle == nil ? .workspace : .task,
            detail: Self.detail(for: phase, displayName: "Claude"),
            model: Self.bounded(model, maximumUTF8Bytes: 128),
            projectPath: workingDirectory,
            jumpURL: nil,
            latestUserPrompt: latestUserPrompt,
            latestAgentResponse: latestAgentResponse,
            latestConversationUpdatedAt: latestConversationUpdatedAt,
            phase: phase,
            updatedAt: updatedAt ?? fallbackUpdatedAt,
            evidence: .claudeTranscript
        )
    }

    public static let maximumLineBytes = 2 * 1_024 * 1_024

    private static let interruptMarker = "[Request interrupted by user"
    private static let turnEndingStopReasons: Set<String> = ["end_turn", "stop_sequence", "refusal"]

    private mutating func consumeClaude(line data: Data) {
        guard let line = try? JSONDecoder().decode(ClaudeLine.self, from: data) else { return }
        guard line.isSidechain != true else { return }

        sessionID = Self.prefer(line.sessionID, over: sessionID, maximumUTF8Bytes: 512)
        workingDirectory = Self.prefer(line.cwd, over: workingDirectory, maximumUTF8Bytes: 4_096)
        model = Self.prefer(line.message?.model, over: model, maximumUTF8Bytes: 128)
        let lineTimestamp = Self.parseDate(line.timestamp)
        updatedAt = Self.latest(updatedAt, lineTimestamp)

        switch line.type?.lowercased() {
        case "ai-title":
            taskTitle = Self.previewText(line.aiTitle) ?? taskTitle
        case "last-prompt":
            if let prompt = Self.previewText(line.lastPrompt) {
                latestUserPrompt = prompt
                latestConversationUpdatedAt = Self.latest(
                    latestConversationUpdatedAt,
                    lineTimestamp
                )
            }
        case "user":
            let text = line.message?.content?.visibleText
            // Claude Code writes this marker when the owner presses Esc, and no
            // Stop hook fires for an interrupt, so the transcript is the signal.
            if text?.contains(Self.interruptMarker) == true {
                phase = .completed
                break
            }
            if line.message?.role == "user",
               let prompt = Self.previewText(text) {
                latestUserPrompt = prompt
                latestConversationUpdatedAt = Self.latest(
                    latestConversationUpdatedAt,
                    lineTimestamp
                )
            }
            phase = .working
        case "assistant":
            if line.message?.role == "assistant",
               let response = Self.previewText(line.message?.content?.visibleText) {
                latestAgentResponse = response
                latestConversationUpdatedAt = Self.latest(
                    latestConversationUpdatedAt,
                    lineTimestamp
                )
            }
            // `end_turn` closes the turn and Claude waits for the owner.
            // `tool_use`, and streamed blocks with no reason yet, mean it is
            // still working.
            phase = Self.turnEndingStopReasons.contains(line.message?.stopReason ?? "")
                ? .completed
                : .working
        case "progress":
            phase = .working
        case "result", "summary":
            phase = .completed
        case "error":
            phase = .failed
        default:
            break
        }
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func detail(for phase: SessionPhase, displayName: String) -> String {
        switch phase {
        case .working: "\(displayName) is working"
        case .waitingForApproval: "Approval needed in \(displayName)"
        case .waitingForAnswer: "Input needed in \(displayName)"
        case .completed: "\(displayName) turn complete"
        case .failed: "\(displayName) turn stopped"
        }
    }

    private static func prefer(
        _ candidate: String?,
        over existing: String?,
        maximumUTF8Bytes: Int
    ) -> String? {
        bounded(candidate, maximumUTF8Bytes: maximumUTF8Bytes) ?? existing
    }

    private static func bounded(_ value: String?, maximumUTF8Bytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return nil }
        return trimmed
    }

    private static func previewText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let maximumCharacters = 2_000
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private struct ClaudeLine: Decodable {
        let sessionID: String?
        let cwd: String?
        let timestamp: String?
        let type: String?
        let message: Message?
        let aiTitle: String?
        let lastPrompt: String?
        let isSidechain: Bool?

        struct Message: Decodable {
            let model: String?
            let role: String?
            let content: Content?
            let stopReason: String?

            private enum CodingKeys: String, CodingKey {
                case model, role, content
                case stopReason = "stop_reason"
            }
        }

        enum Content: Decodable {
            case text(String)
            case blocks([Block])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else {
                    self = .blocks(try container.decode([Block].self))
                }
            }

            var visibleText: String? {
                switch self {
                case let .text(text):
                    text
                case let .blocks(blocks):
                    blocks
                        .filter { $0.type == "text" }
                        .compactMap(\.text)
                        .joined(separator: "\n")
                }
            }
        }

        struct Block: Decodable {
            let type: String?
            let text: String?
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "sessionId"
            case cwd
            case timestamp
            case type
            case message
            case aiTitle
            case lastPrompt
            case isSidechain
        }
    }
}
