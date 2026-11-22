import Foundation

/// Streams Claude Code transcript JSONL into `TranscriptInsights`, one line
/// at a time, so a tailer can feed appended lines without re-reading the file.
///
/// Privacy is structural: the private decoding types below have no fields for
/// prompt, response, thinking, or tool-output text, so that text is never
/// materialized beyond the JSON parser. User text is inspected only for the
/// interrupt marker and reduced to a flag while decoding.
public struct TranscriptInsightsScanner: Sendable {
    public private(set) var insights: TranscriptInsights = .empty

    /// Usage already counted per assistant message id, so repeated streamed
    /// lines add nothing. Bounded because a long session would otherwise grow
    /// it forever; repeats of one id arrive close together.
    private var countedUsage: [String: Usage] = [:]
    private var countedUsageOrder: [String] = []
    private var seenFilePaths: Set<String> = []
    private var seenPullRequests: Set<LinkedPullRequest> = []
    /// Tool-use ids parallel to `insights.testRuns`, kept out of the public
    /// type so `TestRun` stays exactly the integration shape.
    private var testRunToolIDs: [String] = []

    public init() {}

    /// Large enough for Write calls and tool results that embed whole files,
    /// which still carry the ids and paths this scanner needs.
    public static let maximumLineBytes = 16 * 1_024 * 1_024
    static let maximumFilesTouched = 200
    static let maximumTestRuns = 50
    static let maximumAgents = 200
    static let maximumCompactions = 100
    static let maximumPullRequests = 50
    private static let maximumCountedMessageIDs = 1_024

    static let interruptMarker = "[Request interrupted by user"
    private static let turnEndingStopReasons: Set<String> = ["end_turn", "stop_sequence", "refusal"]

    public mutating func consume(line data: Data) {
        guard !data.isEmpty, data.count <= Self.maximumLineBytes else { return }
        guard let line = try? JSONDecoder().decode(Line.self, from: data) else { return }
        // Subagent lines describe the subagent's own context and tools, not
        // the session the owner is watching.
        guard line.isSidechain != true else { return }

        let timestamp = Self.parseDate(line.timestamp)
        if let timestamp {
            insights.lastUpdated = max(insights.lastUpdated ?? timestamp, timestamp)
        }
        if let branch = Self.bounded(line.gitBranch, maximumUTF8Bytes: 256), branch != "HEAD" {
            insights.gitBranch = branch
        }

        switch line.type {
        case "assistant":
            if let message = line.assistant { consume(assistant: message, at: timestamp) }
        case "user":
            if let message = line.user { consume(user: message, at: timestamp) }
        case "system":
            if line.subtype == "compact_boundary" { consumeCompaction(line.compaction, at: timestamp) }
        case "cost-state":
            if let cost = line.cost { insights.cost = cost }
        case "pr-link":
            if let pullRequest = line.pullRequest { record(pullRequest) }
        default:
            break
        }
    }

    // MARK: Line kinds

    private mutating func consume(assistant message: AssistantMessage, at timestamp: Date?) {
        // `<synthetic>` marks locally generated messages (API errors, "no
        // response requested") whose zero usage would blank the gauge.
        if let model = Self.bounded(message.model, maximumUTF8Bytes: 128), !model.hasPrefix("<") {
            insights.model = model
        }
        if let usage = message.usage {
            count(usage, messageID: Self.bounded(message.id, maximumUTF8Bytes: 256))
            if usage.promptTokens > 0 { insights.contextTokens = usage.promptTokens }
        }
        recomputeContext()

        for tool in message.toolUses {
            consume(tool: tool, at: timestamp)
        }
        if let stopReason = message.stopReason, Self.turnEndingStopReasons.contains(stopReason) {
            insights.activity = nil
        }
    }

    private mutating func consume(tool: ToolUse, at timestamp: Date?) {
        guard let name = Self.bounded(tool.name, maximumUTF8Bytes: 256) else { return }
        insights.activity = ToolActivity(toolName: name, startedAt: timestamp)
        let id = Self.bounded(tool.id, maximumUTF8Bytes: 256)

        switch ToolActivityKind(toolName: name) {
        case .writing:
            if let path = Self.bounded(tool.input.filePath, maximumUTF8Bytes: 4_096) {
                recordFile(path)
            }
        case .delegating:
            guard let id, !insights.agents.contains(where: { $0.id == id }) else { return }
            insights.agents.append(AgentRun(
                id: id,
                description: Self.singleLine(tool.input.description, maximumCharacters: 200),
                subagentType: Self.bounded(tool.input.subagentType, maximumUTF8Bytes: 128),
                model: Self.bounded(tool.input.model, maximumUTF8Bytes: 128),
                runsInBackground: tool.input.runInBackground ?? false,
                startedAt: timestamp
            ))
            Self.trim(&insights.agents, to: Self.maximumAgents)
        case .executing:
            guard name == "Bash",
                  let id, !testRunToolIDs.contains(id),
                  let command = tool.input.command,
                  let runner = TranscriptInsightsTestCommand.testRunnerCommand(from: command) else { return }
            insights.testRuns.append(TestRun(command: runner, startedAt: timestamp))
            testRunToolIDs.append(id)
            if insights.testRuns.count > Self.maximumTestRuns {
                insights.testRuns.removeFirst(insights.testRuns.count - Self.maximumTestRuns)
                testRunToolIDs.removeFirst(testRunToolIDs.count - Self.maximumTestRuns)
            }
        default:
            break
        }
    }

    private mutating func consume(user message: UserMessage, at timestamp: Date?) {
        if message.isInterrupt {
            insights.activity = nil
        }
        for result in message.toolResults {
            let failed = result.isError == true
            if let index = insights.agents.lastIndex(where: { $0.id == result.toolUseID }),
               insights.agents[index].finishedAt == nil {
                // A result without a timestamp must still end the run, so fall
                // back to the latest known time rather than leave it running.
                insights.agents[index].finishedAt = timestamp
                    ?? insights.lastUpdated
                    ?? insights.agents[index].startedAt
                    ?? .distantPast
                insights.agents[index].failed = failed
            }
            if let index = testRunToolIDs.lastIndex(of: result.toolUseID) {
                insights.testRuns[index].outcome = failed ? .failed : .passed
            }
        }
    }

    private mutating func consumeCompaction(_ metadata: CompactionMetadata?, at timestamp: Date?) {
        insights.compactions.append(CompactionEvent(
            at: timestamp,
            trigger: Self.bounded(metadata?.trigger, maximumUTF8Bytes: 64),
            preTokens: metadata?.preTokens,
            postTokens: metadata?.postTokens
        ))
        Self.trim(&insights.compactions, to: Self.maximumCompactions)
        // The pre-compaction prompt size no longer describes the window; use
        // the reported post size until the next assistant usage arrives.
        insights.contextTokens = metadata?.postTokens
        recomputeContext()
    }

    // MARK: Accumulators

    private mutating func count(_ usage: Usage, messageID: String?) {
        guard let messageID else {
            add(usage, sign: 1)
            return
        }
        if let previous = countedUsage[messageID] {
            // Streamed lines normally repeat identical usage; if a later line
            // reports more, count only the growth so the message stays once.
            let merged = previous.fieldwiseMax(usage)
            add(previous, sign: -1)
            add(merged, sign: 1)
            countedUsage[messageID] = merged
            return
        }
        add(usage, sign: 1)
        countedUsage[messageID] = usage
        countedUsageOrder.append(messageID)
        if countedUsageOrder.count > Self.maximumCountedMessageIDs {
            countedUsage.removeValue(forKey: countedUsageOrder.removeFirst())
        }
    }

    private mutating func add(_ usage: Usage, sign: Int) {
        insights.cache.inputTokens += sign * usage.input
        insights.cache.cacheReadTokens += sign * usage.cacheRead
        insights.cache.cacheCreationTokens += sign * usage.cacheCreation
        insights.cache.outputTokens += sign * usage.output
    }

    private mutating func recomputeContext() {
        insights.contextWindowTokens = ContextWindow.size(
            forModel: insights.model,
            observedTokens: insights.contextTokens
        )
        if let tokens = insights.contextTokens, let window = insights.contextWindowTokens, window > 0 {
            insights.contextFraction = min(max(Double(tokens) / Double(window), 0), 1)
        } else {
            insights.contextFraction = nil
        }
    }

    private mutating func recordFile(_ path: String) {
        guard insights.filesTouched.count < Self.maximumFilesTouched,
              seenFilePaths.insert(path).inserted else { return }
        insights.filesTouched.append(path)
    }

    private mutating func record(_ pullRequest: LinkedPullRequest) {
        guard insights.pullRequests.count < Self.maximumPullRequests,
              seenPullRequests.insert(pullRequest).inserted else { return }
        insights.pullRequests.append(pullRequest)
    }

    private static func trim<Element>(_ values: inout [Element], to maximum: Int) {
        if values.count > maximum { values.removeFirst(values.count - maximum) }
    }

    // MARK: Text bounds

    private static func bounded(_ value: String?, maximumUTF8Bytes: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return nil }
        return trimmed
    }

    private static func singleLine(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters - 1)) + "…"
    }

    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondDateStyle = Date.ISO8601FormatStyle()

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return (try? fractionalDateStyle.parse(value)) ?? (try? wholeSecondDateStyle.parse(value))
    }
}

// MARK: - Decoding

/// Every field decodes leniently: Claude Code adds and reshapes fields across
/// releases, and one surprising value must not discard the facts beside it.
extension TranscriptInsightsScanner {
    struct Usage: Equatable, Sendable, Decodable {
        var input = 0
        var cacheRead = 0
        var cacheCreation = 0
        var output = 0

        var promptTokens: Int { input + cacheRead + cacheCreation }

        init(input: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0, output: Int = 0) {
            self.input = input
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.output = output
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            input = max(values.lenientInt(.input) ?? 0, 0)
            cacheRead = max(values.lenientInt(.cacheRead) ?? 0, 0)
            cacheCreation = max(values.lenientInt(.cacheCreation) ?? 0, 0)
            output = max(values.lenientInt(.output) ?? 0, 0)
        }

        func fieldwiseMax(_ other: Usage) -> Usage {
            Usage(
                input: max(input, other.input),
                cacheRead: max(cacheRead, other.cacheRead),
                cacheCreation: max(cacheCreation, other.cacheCreation),
                output: max(output, other.output)
            )
        }

        private enum Key: String, CodingKey {
            case input = "input_tokens"
            case cacheRead = "cache_read_input_tokens"
            case cacheCreation = "cache_creation_input_tokens"
            case output = "output_tokens"
        }
    }

    /// Only the top-level fields and the payload for this line's `type` are
    /// decoded, so unrelated large payloads are parsed but never copied out.
    private struct Line: Decodable {
        var type: String?
        var isSidechain: Bool?
        var timestamp: String?
        var gitBranch: String?
        var assistant: AssistantMessage?
        var user: UserMessage?
        var subtype: String?
        var compaction: CompactionMetadata?
        var cost: SessionCost?
        var pullRequest: LinkedPullRequest?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            type = values.lenient(String.self, .type)
            isSidechain = values.lenient(Bool.self, .isSidechain)
            timestamp = values.lenient(String.self, .timestamp)
            gitBranch = values.lenient(String.self, .gitBranch)

            switch type {
            case "assistant":
                assistant = values.lenient(AssistantMessage.self, .message)
            case "user":
                user = values.lenient(UserMessage.self, .message)
            case "system":
                subtype = values.lenient(String.self, .subtype)
                if subtype == "compact_boundary" {
                    compaction = values.lenient(CompactionMetadata.self, .compactMetadata)
                }
            case "cost-state":
                let cost = SessionCost(
                    totalUSD: values.lenientDouble(.totalCostUSD),
                    linesAdded: values.lenientInt(.totalLinesAdded),
                    linesRemoved: values.lenientInt(.totalLinesRemoved),
                    durationMs: values.lenientInt(.totalDuration),
                    apiDurationMs: values.lenientInt(.totalAPIDuration)
                )
                // An empty cost line carries no totals; keeping the previous
                // ones is more truthful than blanking them.
                let hasTotals = cost.totalUSD != nil || cost.linesAdded != nil || cost.linesRemoved != nil
                    || cost.durationMs != nil || cost.apiDurationMs != nil
                self.cost = hasTotals ? cost : nil
            case "pr-link":
                if let number = values.lenientInt(.prNumber), number > 0,
                   let url = values.lenient(String.self, .prUrl), !url.isEmpty, url.utf8.count <= 2_048,
                   let repository = values.lenient(String.self, .prRepository),
                   !repository.isEmpty, repository.utf8.count <= 512 {
                    pullRequest = LinkedPullRequest(number: number, url: url, repository: repository)
                }
            default:
                break
            }
        }

        private enum Key: String, CodingKey {
            case type, isSidechain, timestamp, gitBranch, message, subtype, compactMetadata
            case totalCostUSD, totalLinesAdded, totalLinesRemoved, totalDuration, totalAPIDuration
            case prNumber, prUrl, prRepository
        }
    }

    private struct AssistantMessage: Decodable {
        var id: String?
        var model: String?
        var stopReason: String?
        var usage: Usage?
        var toolUses: [ToolUse] = []

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            id = values.lenient(String.self, .id)
            model = values.lenient(String.self, .model)
            stopReason = values.lenient(String.self, .stopReason)
            usage = values.lenient(Usage.self, .usage)
            if var blocks = try? values.nestedUnkeyedContainer(forKey: .content) {
                while !blocks.isAtEnd {
                    if let block = try? blocks.decode(AssistantBlock.self) {
                        if let tool = block.toolUse { toolUses.append(tool) }
                    } else {
                        // A failed decode does not advance the container.
                        _ = try? blocks.decode(Skip.self)
                    }
                }
            }
        }

        private enum Key: String, CodingKey {
            case id, model, usage, content
            case stopReason = "stop_reason"
        }
    }

    /// Text and thinking blocks are recognized only by `type` and never read.
    private struct AssistantBlock: Decodable {
        var toolUse: ToolUse?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            guard values.lenient(String.self, .type) == "tool_use" else { return }
            let name = values.lenient(String.self, .name)
            var input = ToolInput()
            if let name, let inputDecoder = try? values.superDecoder(forKey: .input) {
                input = (try? ToolInput(from: inputDecoder, toolName: name)) ?? ToolInput()
            }
            toolUse = ToolUse(id: values.lenient(String.self, .id), name: name, input: input)
        }

        private enum Key: String, CodingKey {
            case type, id, name, input
        }
    }

    private struct ToolUse {
        var id: String?
        var name: String?
        var input: ToolInput
    }

    /// Reads only the input keys a given tool needs, so Write `content`,
    /// Edit strings, and Agent prompts stay unread.
    private struct ToolInput {
        var filePath: String?
        var command: String?
        var description: String?
        var subagentType: String?
        var model: String?
        var runInBackground: Bool?

        init() {}

        init(from decoder: Decoder, toolName: String) throws {
            let values = try decoder.container(keyedBy: Key.self)
            switch toolName {
            case "Edit", "MultiEdit", "Write":
                filePath = values.lenient(String.self, .filePath)
            case "NotebookEdit":
                // NotebookEdit names its target `notebook_path`.
                filePath = values.lenient(String.self, .notebookPath) ?? values.lenient(String.self, .filePath)
            case "Bash":
                command = values.lenient(String.self, .command)
            case "Agent", "Task":
                description = values.lenient(String.self, .description)
                subagentType = values.lenient(String.self, .subagentType)
                model = values.lenient(String.self, .model)
                runInBackground = values.lenient(Bool.self, .runInBackground)
            default:
                break
            }
        }

        private enum Key: String, CodingKey {
            case command, description, model
            case filePath = "file_path"
            case notebookPath = "notebook_path"
            case subagentType = "subagent_type"
            case runInBackground = "run_in_background"
        }
    }

    struct ToolResult: Equatable {
        var toolUseID: String
        var isError: Bool?
    }

    /// User content reduced to what insights need: tool-result ids and an
    /// interrupt flag. Prompt text is checked for the marker and dropped.
    private struct UserMessage: Decodable {
        var isInterrupt = false
        var toolResults: [ToolResult] = []

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            if let text = values.lenient(String.self, .content) {
                isInterrupt = text.contains(TranscriptInsightsScanner.interruptMarker)
                return
            }
            guard var blocks = try? values.nestedUnkeyedContainer(forKey: .content) else { return }
            while !blocks.isAtEnd {
                if let block = try? blocks.decode(UserBlock.self) {
                    isInterrupt = isInterrupt || block.isInterrupt
                    if let result = block.toolResult { toolResults.append(result) }
                } else {
                    _ = try? blocks.decode(Skip.self)
                }
            }
        }

        private enum Key: String, CodingKey {
            case content
        }
    }

    private struct UserBlock: Decodable {
        var isInterrupt = false
        var toolResult: ToolResult?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            switch values.lenient(String.self, .type) {
            case "text":
                isInterrupt = values.lenient(String.self, .text)?
                    .contains(TranscriptInsightsScanner.interruptMarker) == true
            case "tool_result":
                // The result body is never decoded; only its id and error flag.
                if let id = values.lenient(String.self, .toolUseID), !id.isEmpty {
                    toolResult = ToolResult(toolUseID: id, isError: values.lenient(Bool.self, .isError))
                }
            default:
                break
            }
        }

        private enum Key: String, CodingKey {
            case type, text
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }
    }

    private struct CompactionMetadata: Decodable {
        var trigger: String?
        var preTokens: Int?
        var postTokens: Int?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            trigger = values.lenient(String.self, .trigger)
            preTokens = values.lenientInt(.preTokens)
            postTokens = values.lenientInt(.postTokens)
        }

        private enum Key: String, CodingKey {
            case trigger, preTokens, postTokens
        }
    }

    /// Consumes one array element of any shape so a malformed block can be
    /// stepped over.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

private extension KeyedDecodingContainer {
    func lenient<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Accepts integral doubles too: durations and counts are sometimes
    /// serialized as `123.0`, which strict `Int` decoding rejects.
    func lenientInt(_ key: Key) -> Int? {
        if let value = lenient(Int.self, key) { return value }
        guard let value = lenient(Double.self, key), value.isFinite,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    func lenientDouble(_ key: Key) -> Double? {
        guard let value = lenient(Double.self, key), value.isFinite else { return nil }
        return value
    }
}
