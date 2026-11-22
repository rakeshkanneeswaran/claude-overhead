import Foundation
import Testing
@testable import ChimloCore

/// Synthetic transcript lines shaped like Claude Code's JSONL. Built through
/// JSONSerialization so fixtures stay readable and correctly escaped.
private enum Fixture {
    static let start = "2026-11-22T10:00:00.000Z"

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func timestamp(_ second: Int) -> String {
        String(format: "2026-11-22T10:%02d:%02d.250Z", second / 60, second % 60)
    }

    static func date(_ second: Int) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp(second))
    }

    static func usage(input: Int = 0, read: Int = 0, creation: Int = 0, output: Int = 0) -> [String: Any] {
        [
            "input_tokens": input,
            "cache_read_input_tokens": read,
            "cache_creation_input_tokens": creation,
            "output_tokens": output,
        ]
    }

    static func assistant(
        id: String = "msg_1",
        model: String = "claude-opus-4-5-20251101",
        stopReason: String? = nil,
        usage: [String: Any]? = nil,
        content: [Any] = [],
        second: Int = 0,
        sidechain: Bool = false,
        branch: String? = nil
    ) -> String {
        var message: [String: Any] = ["id": id, "model": model, "role": "assistant", "content": content]
        // Streaming lines carry an explicit null stop reason.
        message["stop_reason"] = stopReason.map { $0 as Any } ?? NSNull()
        if let usage { message["usage"] = usage }
        var line: [String: Any] = [
            "type": "assistant",
            "sessionId": "session-1",
            "timestamp": timestamp(second),
            "isSidechain": sidechain,
            "message": message,
        ]
        if let branch { line["gitBranch"] = branch }
        return json(line)
    }

    static func toolUse(_ id: String, _ name: String, _ input: [String: Any] = [:]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func tool(
        _ id: String,
        _ name: String,
        _ input: [String: Any] = [:],
        second: Int = 0,
        sidechain: Bool = false
    ) -> String {
        assistant(
            id: "msg_\(id)",
            stopReason: "tool_use",
            content: [toolUse(id, name, input)],
            second: second,
            sidechain: sidechain
        )
    }

    static func endTurn(second: Int = 0) -> String {
        assistant(
            id: "msg_end_\(second)",
            stopReason: "end_turn",
            content: [["type": "text", "text": "Done."]],
            second: second
        )
    }

    static func user(_ content: Any, second: Int = 0, branch: String? = nil, sidechain: Bool = false) -> String {
        var line: [String: Any] = [
            "type": "user",
            "sessionId": "session-1",
            "timestamp": timestamp(second),
            "isSidechain": sidechain,
            "message": ["role": "user", "content": content],
        ]
        if let branch { line["gitBranch"] = branch }
        return json(line)
    }

    static func result(_ toolUseID: String, isError: Bool? = nil, second: Int = 0) -> String {
        var block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseID,
            "content": "tool output body",
        ]
        if let isError { block["is_error"] = isError }
        return user([block], second: second)
    }

    static func compactBoundary(trigger: String = "auto", pre: Int?, post: Int?, second: Int = 0) -> String {
        var metadata: [String: Any] = ["trigger": trigger, "durationMs": 4_200]
        if let pre { metadata["preTokens"] = pre }
        if let post { metadata["postTokens"] = post }
        return json([
            "type": "system",
            "subtype": "compact_boundary",
            "timestamp": timestamp(second),
            "content": "Conversation compacted",
            "compactMetadata": metadata,
        ])
    }
}

private func scan(_ lines: [String]) -> TranscriptInsights {
    var scanner = TranscriptInsightsScanner()
    for line in lines { scanner.consume(line: Data(line.utf8)) }
    return scanner.insights
}

private func encodedText(_ insights: TranscriptInsights) throws -> String {
    String(decoding: try JSONEncoder().encode(insights), as: UTF8.self)
}

@Suite("Transcript insights")
struct TranscriptInsightsTests {
    // MARK: Pure classification

    @Test("Tool names collapse into a few activity kinds with short labels")
    func toolKindMapping() {
        let expectations: [(String, ToolActivityKind)] = [
            ("Read", .reading), ("NotebookRead", .reading),
            ("Glob", .searching), ("Grep", .searching), ("LS", .searching), ("ToolSearch", .searching),
            ("Edit", .writing), ("MultiEdit", .writing), ("Write", .writing), ("NotebookEdit", .writing),
            ("Bash", .executing), ("BashOutput", .executing), ("KillShell", .executing),
            ("Agent", .delegating), ("Task", .delegating),
            ("AskUserQuestion", .asking),
            ("WebFetch", .browsing), ("WebSearch", .browsing),
            ("mcp__github__create_issue", .other), ("Skill", .other), ("TodoWrite", .other), ("", .other),
        ]
        for (name, kind) in expectations {
            #expect(ToolActivityKind(toolName: name) == kind, "\(name)")
        }

        let labels: [ToolActivityKind: String] = [
            .reading: "Reading files", .searching: "Searching", .writing: "Writing files",
            .executing: "Running a command", .delegating: "Delegating to agents", .asking: "Asking you",
            .browsing: "Browsing the web", .other: "Working",
        ]
        #expect(ToolActivityKind.allCases.count == labels.count)
        for kind in ToolActivityKind.allCases {
            #expect(kind.label == labels[kind])
        }
    }

    @Test("Context health crosses attention and critical thresholds inclusively")
    func healthThresholds() {
        #expect(ContextHealth.classify(fraction: 0) == .healthy)
        #expect(ContextHealth.classify(fraction: 0.69) == .healthy)
        #expect(ContextHealth.classify(fraction: 0.7) == .attention)
        #expect(ContextHealth.classify(fraction: 0.89) == .attention)
        #expect(ContextHealth.classify(fraction: 0.9) == .critical)
        #expect(ContextHealth.classify(fraction: 1) == .critical)
        #expect(ContextHealth.classify(fraction: 0.5, attentionAt: 0.4, criticalAt: 0.6) == .attention)
        #expect(ContextHealth.classify(fraction: 0.6, attentionAt: 0.4, criticalAt: 0.6) == .critical)
        #expect(ContextHealth.classify(fraction: .nan) == .healthy)
    }

    @Test("Context window sizes come from the model id, with 1M detection")
    func contextWindowSizes() {
        #expect(ContextWindow.size(forModel: nil) == nil)
        #expect(ContextWindow.size(forModel: "claude-sonnet-4-5[1m]") == 1_000_000)
        #expect(ContextWindow.size(forModel: "claude-sonnet-4-5-1m") == 1_000_000)
        #expect(ContextWindow.size(forModel: "claude-opus-4-5-20251101") == 200_000)
        #expect(ContextWindow.size(forModel: "Claude-Haiku-4-5") == 200_000)
        #expect(ContextWindow.size(forModel: "gpt-5") == nil)

        // The 1M window is a request header, so usage above 200K proves it.
        #expect(ContextWindow.size(forModel: "claude-sonnet-4-5", observedTokens: 350_000) == 1_000_000)
        #expect(ContextWindow.size(forModel: "claude-sonnet-4-5", observedTokens: 150_000) == 200_000)
        #expect(ContextWindow.size(forModel: "gpt-5", observedTokens: 350_000) == nil)
    }

    // MARK: Context

    @Test("Context fraction counts input plus both cache token kinds, from the latest usage")
    func contextFractionIncludesCache() {
        let first = Fixture.assistant(
            id: "msg_1",
            model: "claude-sonnet-4-5-20250929",
            usage: Fixture.usage(input: 1_000, read: 120_000, creation: 19_000, output: 900)
        )
        var insights = scan([first])
        #expect(insights.model == "claude-sonnet-4-5-20250929")
        #expect(insights.contextTokens == 140_000)
        #expect(insights.contextWindowTokens == 200_000)
        #expect(insights.contextFraction == 0.7)
        #expect(insights.contextHealth == .attention)

        let second = Fixture.assistant(
            id: "msg_2",
            model: "claude-sonnet-4-5-20250929",
            usage: Fixture.usage(input: 10, read: 50_000, creation: 0, output: 5)
        )
        insights = scan([first, second])
        #expect(insights.contextTokens == 50_010)
        #expect(insights.contextHealth == .healthy)
    }

    @Test("A 1M model or usage beyond 200K uses the extended window")
    func extendedWindowFraction() {
        let explicit = scan([Fixture.assistant(
            model: "claude-sonnet-4-5[1m]",
            usage: Fixture.usage(input: 500_000)
        )])
        #expect(explicit.contextWindowTokens == 1_000_000)
        #expect(explicit.contextFraction == 0.5)

        let inferred = scan([Fixture.assistant(
            model: "claude-sonnet-4-5-20250929",
            usage: Fixture.usage(input: 100, read: 299_900)
        )])
        #expect(inferred.contextWindowTokens == 1_000_000)
        #expect(inferred.contextFraction == 0.3)
    }

    @Test("Synthetic assistant messages do not blank the model or the gauge")
    func syntheticMessagesIgnoredForContext() {
        let insights = scan([
            Fixture.assistant(id: "msg_1", usage: Fixture.usage(input: 20_000)),
            Fixture.assistant(id: "msg_2", model: "<synthetic>", usage: Fixture.usage()),
        ])
        #expect(insights.model == "claude-opus-4-5-20251101")
        #expect(insights.contextTokens == 20_000)
        #expect(insights.contextFraction == 0.1)
    }

    @Test("A compaction is recorded and resets context until the next usage")
    func compactionResetsContext() throws {
        let before = Fixture.assistant(id: "msg_1", usage: Fixture.usage(input: 2_000, read: 178_000), second: 1)
        let boundary = Fixture.compactBoundary(pre: 180_000, post: 12_000, second: 2)
        let after = Fixture.assistant(id: "msg_2", usage: Fixture.usage(input: 30_000), second: 3)

        let critical = scan([before])
        #expect(critical.contextHealth == .critical)

        let compacted = scan([before, boundary])
        let event = try #require(compacted.compactions.first)
        #expect(compacted.compactions.count == 1)
        #expect(event == CompactionEvent(at: Fixture.date(2), trigger: "auto", preTokens: 180_000, postTokens: 12_000))
        #expect(compacted.contextTokens == 12_000)
        #expect(compacted.contextFraction == 0.06)

        let resumed = scan([before, boundary, after])
        #expect(resumed.contextTokens == 30_000)
        #expect(resumed.contextFraction == 0.15)

        let unknownPost = scan([before, Fixture.compactBoundary(trigger: "manual", pre: 180_000, post: nil)])
        #expect(unknownPost.compactions.first?.trigger == "manual")
        #expect(unknownPost.contextTokens == nil)
        #expect(unknownPost.contextFraction == nil)
    }

    // MARK: Cache

    @Test("Cache totals count each assistant message id once")
    func cacheDedupeAndHitRatio() {
        #expect(TranscriptInsights.empty.cache.hitRatio == nil)

        let usage = Fixture.usage(input: 10, read: 900, creation: 90, output: 5)
        let insights = scan([
            // One streamed message: thinking, text, and a tool call as three lines.
            Fixture.assistant(id: "msg_1", usage: usage, content: [["type": "thinking", "thinking": "hmm"]]),
            Fixture.assistant(id: "msg_1", usage: usage, content: [["type": "text", "text": "Reading."]]),
            Fixture.assistant(id: "msg_1", stopReason: "tool_use", usage: usage, content: [Fixture.toolUse("toolu_1", "Read")]),
            Fixture.result("toolu_1"),
            Fixture.assistant(id: "msg_2", usage: Fixture.usage(input: 5, read: 1_000, output: 7)),
            // If a later block reports more output, only the growth counts.
            Fixture.assistant(id: "msg_3", usage: Fixture.usage(output: 1)),
            Fixture.assistant(id: "msg_3", usage: Fixture.usage(output: 20)),
        ])
        #expect(insights.cache == CacheStats(
            inputTokens: 15,
            cacheReadTokens: 1_900,
            cacheCreationTokens: 90,
            outputTokens: 32
        ))
        #expect(insights.cache.hitRatio == 1_900.0 / 2_005.0)
        #expect(CacheStats(outputTokens: 50).hitRatio == nil)
    }

    // MARK: Activity

    @Test("Activity follows the latest tool call and clears when the turn ends")
    func activityLifecycle() throws {
        let bash = Fixture.tool("toolu_1", "Bash", ["command": "ls", "description": "List"], second: 1)
        let running = scan([bash])
        let activity = try #require(running.activity)
        #expect(activity == ToolActivity(kind: .executing, toolName: "Bash", startedAt: Fixture.date(1)))
        #expect(activity.kind.label == "Running a command")

        let read = Fixture.tool("toolu_2", "Read", ["file_path": "/tmp/a.swift"], second: 2)
        #expect(scan([bash, Fixture.result("toolu_1"), read]).activity?.kind == .reading)

        // A streamed text block without a stop reason keeps the tool visible.
        let streaming = Fixture.assistant(id: "msg_x", content: [["type": "text", "text": "Looking"]], second: 3)
        #expect(scan([bash, streaming]).activity?.toolName == "Bash")

        #expect(scan([bash, Fixture.result("toolu_1"), Fixture.endTurn(second: 4)]).activity == nil)
    }

    @Test("Activity clears on the interrupt marker in text or block content")
    func activityClearedByInterrupt() {
        let search = Fixture.tool("toolu_1", "Grep", ["pattern": "TODO"])
        #expect(scan([search]).activity?.kind == .searching)
        #expect(scan([search, Fixture.user("[Request interrupted by user]")]).activity == nil)
        #expect(scan([
            search,
            Fixture.result("toolu_1", isError: true),
            Fixture.user([["type": "text", "text": "[Request interrupted by user for tool use]"]]),
        ]).activity == nil)
        // An ordinary prompt is not an interrupt.
        #expect(scan([search, Fixture.user("keep going")]).activity?.kind == .searching)
    }

    @Test("Subagent sidechain lines never affect the main session's insights")
    func sidechainIgnored() {
        let insights = scan([
            Fixture.assistant(id: "msg_main", usage: Fixture.usage(input: 1_000, read: 9_000), branch: "main"),
            Fixture.assistant(
                id: "msg_side",
                model: "claude-haiku-4-5",
                stopReason: "tool_use",
                usage: Fixture.usage(input: 50_000, read: 50_000),
                content: [
                    Fixture.toolUse("toolu_side_write", "Write", ["file_path": "/tmp/side.swift", "content": "x"]),
                    Fixture.toolUse("toolu_side_agent", "Agent", ["description": "Nested"]),
                    Fixture.toolUse("toolu_side_test", "Bash", ["command": "swift test"]),
                ],
                sidechain: true,
                branch: "side-branch"
            ),
            Fixture.user("[Request interrupted by user]", sidechain: true),
        ])
        #expect(insights.model == "claude-opus-4-5-20251101")
        #expect(insights.contextTokens == 10_000)
        #expect(insights.cache == CacheStats(inputTokens: 1_000, cacheReadTokens: 9_000))
        #expect(insights.activity == nil)
        #expect(insights.agents.isEmpty)
        #expect(insights.filesTouched.isEmpty)
        #expect(insights.testRuns.isEmpty)
        #expect(insights.gitBranch == "main")
    }

    // MARK: Agents

    @Test("Agent runs start on tool_use and finish or fail on the matching tool_result")
    func agentLifecycle() throws {
        let launch = Fixture.assistant(
            id: "msg_agents",
            stopReason: "tool_use",
            content: [
                Fixture.toolUse("toolu_a1", "Agent", [
                    "description": "  Explore   the\nrepo ",
                    "subagent_type": "Explore",
                    "model": "haiku",
                    "prompt": "SECRET-AGENT-PROMPT",
                    "run_in_background": true,
                ]),
                Fixture.toolUse("toolu_a2", "Task", ["description": "Review diff", "prompt": "SECRET-AGENT-PROMPT"]),
            ],
            second: 1
        )
        let started = scan([launch, launch])
        #expect(started.agents.count == 2)
        let allRunning = started.agents.allSatisfy(\.isRunning)
        #expect(allRunning)
        #expect(started.runningAgents.count == 2)
        #expect(started.activity?.kind == .delegating)
        let first = try #require(started.agents.first)
        #expect(first == AgentRun(
            id: "toolu_a1",
            description: "Explore the repo",
            subagentType: "Explore",
            model: "haiku",
            runsInBackground: true,
            startedAt: Fixture.date(1)
        ))
        #expect(started.agents.last?.runsInBackground == false)

        let finished = scan([
            launch,
            Fixture.result("toolu_a1", isError: false, second: 5),
            Fixture.result("toolu_a2", isError: true, second: 7),
            Fixture.result("toolu_unrelated", isError: true, second: 8),
        ])
        #expect(finished.agents.map(\.finishedAt) == [Fixture.date(5), Fixture.date(7)])
        #expect(finished.agents.map(\.failed) == [false, true])
        #expect(finished.runningAgents.isEmpty)
        #expect(try !encodedText(finished).contains("SECRET"))
    }

    // MARK: Line types

    @Test("Linked pull requests are unique in first-seen order")
    func pullRequestDedupe() {
        func link(_ number: Int, _ repository: String = "acme/app", url: String? = nil) -> String {
            var line: [String: Any] = [
                "type": "pr-link",
                "prNumber": number,
                "prRepository": repository,
                "timestamp": Fixture.start,
            ]
            line["prUrl"] = url ?? "https://github.com/\(repository)/pull/\(number)"
            return Fixture.json(line)
        }
        let insights = scan([
            link(12),
            link(7, "acme/site"),
            link(12),
            link(9, url: ""),
            #"{"type":"pr-link","prNumber":"ten","prUrl":"https://x/pull/10","prRepository":"acme/app"}"#,
        ])
        #expect(insights.pullRequests == [
            LinkedPullRequest(number: 12, url: "https://github.com/acme/app/pull/12", repository: "acme/app"),
            LinkedPullRequest(number: 7, url: "https://github.com/acme/site/pull/7", repository: "acme/site"),
        ])
    }

    @Test("The latest cost-state line wins")
    func costStateLatestWins() {
        let early = #"{"type":"cost-state","totalCostUSD":0.42,"totalLinesAdded":10,"totalLinesRemoved":2,"totalDuration":60000,"totalAPIDuration":30000,"startTime":1795000000000,"modelUsage":{"claude-opus-4-5":{"inputTokens":1,"outputTokens":2,"costUSD":0.42}}}"#
        let late = #"{"type":"cost-state","totalCostUSD":1.75,"totalLinesAdded":120,"totalLinesRemoved":33,"totalDuration":240000.0,"totalAPIDuration":95000,"futureField":{"nested":true}}"#
        let empty = #"{"type":"cost-state","somethingElse":1}"#

        #expect(scan([early]).cost == SessionCost(
            totalUSD: 0.42, linesAdded: 10, linesRemoved: 2, durationMs: 60_000, apiDurationMs: 30_000
        ))
        let expected = SessionCost(totalUSD: 1.75, linesAdded: 120, linesRemoved: 33, durationMs: 240_000, apiDurationMs: 95_000)
        #expect(scan([early, late]).cost == expected)
        #expect(scan([early, late, empty]).cost == expected)
    }

    @Test("Git branch tracks the latest real branch name")
    func gitBranchTracking() {
        #expect(scan([Fixture.user("hi", branch: "feature/notch")]).gitBranch == "feature/notch")
        #expect(scan([
            Fixture.user("hi", branch: "feature/notch"),
            Fixture.user("hi", branch: ""),
            Fixture.user("hi", branch: "HEAD"),
        ]).gitBranch == "feature/notch")
        #expect(scan([
            Fixture.user("hi", branch: "feature/notch"),
            Fixture.assistant(branch: "main"),
        ]).gitBranch == "main")
    }

    // MARK: Files

    @Test("Files touched are unique editing-tool paths in first-seen order")
    func filesTouchedDedupe() {
        let insights = scan([
            Fixture.tool("t1", "Edit", ["file_path": "/p/a.swift", "old_string": "SECRET-OLD", "new_string": "SECRET-NEW"]),
            Fixture.tool("t2", "Write", ["file_path": "/p/b.swift", "content": "SECRET-CONTENT"]),
            Fixture.tool("t3", "Edit", ["file_path": "/p/a.swift"]),
            Fixture.tool("t4", "MultiEdit", ["file_path": "/p/c.swift", "edits": []]),
            Fixture.tool("t5", "NotebookEdit", ["notebook_path": "/p/d.ipynb", "new_source": "SECRET"]),
            Fixture.tool("t6", "Read", ["file_path": "/p/e.swift"]),
            Fixture.tool("t7", "Write", ["file_path": "   "]),
        ])
        #expect(insights.filesTouched == ["/p/a.swift", "/p/b.swift", "/p/c.swift", "/p/d.ipynb"])
    }

    @Test("Files touched stop growing at 200 paths")
    func filesTouchedCap() {
        let lines = (0..<250).map { Fixture.tool("t\($0)", "Write", ["file_path": "/p/file-\($0).txt"]) }
        let insights = scan(lines)
        #expect(insights.filesTouched.count == 200)
        #expect(insights.filesTouched.first == "/p/file-0.txt")
        #expect(insights.filesTouched.last == "/p/file-199.txt")
    }

    // MARK: Test runs

    @Test("Test-runner commands are recognized across ecosystems")
    func testCommandDetection() {
        let recognized: [(String, String)] = [
            ("swift test", "swift test"),
            ("swift test --filter TranscriptInsightsTests", "swift test --filter TranscriptInsightsTests"),
            ("xcodebuild -scheme App -destination 'platform=macOS' test", "xcodebuild -scheme App -destination 'platform=macOS' test"),
            ("npm test", "npm test"),
            ("pnpm test", "pnpm test"),
            ("yarn test", "yarn test"),
            ("bun test", "bun test"),
            ("npm run test:unit", "npm run test:unit"),
            ("npx jest src", "npx jest src"),
            ("npx vitest run", "npx vitest run"),
            ("jest", "jest"),
            ("vitest --run", "vitest --run"),
            ("pytest -q tests", "pytest -q tests"),
            ("python -m pytest tests", "python -m pytest tests"),
            ("python3 -m pytest", "python3 -m pytest"),
            ("uv run pytest", "uv run pytest"),
            ("go test ./...", "go test ./..."),
            ("cargo test --workspace", "cargo test --workspace"),
            ("make test", "make test"),
            ("mvn test", "mvn test"),
            ("gradle test", "gradle test"),
            ("./gradlew :app:test", "./gradlew :app:test"),
            ("rspec spec/models", "rspec spec/models"),
            ("bundle exec rspec", "bundle exec rspec"),
            ("vendor/bin/phpunit", "vendor/bin/phpunit"),
            // Compound lines keep only the test-runner segment.
            ("cd /Users/someone/proj && swift test 2>&1 | tail -20", "swift test 2>&1"),
            ("make build && make test", "make test"),
            ("(cd pkg; go test ./...)", "go test ./..."),
            // Environment assignments are where secrets live, so they go.
            ("FOO=bar API_KEY=\"s3cr3t value\" npm test", "npm test"),
            ("env TOKEN=abc go test ./...", "go test ./..."),
            ("make test SECRET=xyz", "make test"),
            ("export TOKEN=abc && cargo test", "cargo test"),
        ]
        for (command, expected) in recognized {
            #expect(TranscriptInsightsTestCommand.testRunnerCommand(from: command) == expected, "\(command)")
        }

        let ignored = [
            "swift build", "git commit -m \"swift test\"", "echo npm test", "ls test", "grep -r test .",
            "npm install", "cargo build", "go build ./...", "cat Makefile", "python -m pip install pytest",
            "", "   ",
        ]
        for command in ignored {
            #expect(TranscriptInsightsTestCommand.testRunnerCommand(from: command) == nil, "\(command)")
        }

        let long = "swift test --filter " + String(repeating: "VeryLongTestName", count: 30)
        let truncated = TranscriptInsightsTestCommand.testRunnerCommand(from: long)
        #expect(truncated?.count == 160)
        #expect(truncated?.hasSuffix("…") == true)
    }

    @Test("Test runs take their outcome from the matching tool_result")
    func testRunOutcomes() throws {
        let lines = [
            Fixture.tool("t1", "Bash", ["command": "API_TOKEN=SECRET-VALUE swift test", "description": "Run the tests"], second: 1),
            Fixture.tool("t2", "Bash", ["command": "ls -la"], second: 2),
            Fixture.tool("t3", "Bash", ["command": "npm test"], second: 3),
            Fixture.tool("t4", "Bash", ["command": "go test ./..."], second: 4),
        ]
        let pending = scan(lines)
        #expect(pending.testRuns == [
            TestRun(command: "swift test", startedAt: Fixture.date(1)),
            TestRun(command: "npm test", startedAt: Fixture.date(3)),
            TestRun(command: "go test ./...", startedAt: Fixture.date(4)),
        ])
        #expect(pending.testRuns.allSatisfy { $0.outcome == .unknown })

        let finished = scan(lines + [
            Fixture.result("t1", isError: false),
            Fixture.result("t2", isError: true),
            Fixture.result("t3", isError: true),
            Fixture.result("t4"),
        ])
        #expect(finished.testRuns.map(\.outcome) == [.passed, .failed, .passed])
        // The token's value never survives, in test runs or in the feed.
        #expect(try !encodedText(finished).contains("SECRET"))
        #expect(finished.activities.first?.target == "API_TOKEN=••• swift test")
        #expect(finished.activities.map(\.status) == [.completed, .failed, .failed, .completed])
    }

    @Test("Test runs keep the newest 50 and still resolve their outcomes")
    func testRunCap() {
        var lines = (0..<60).map { Fixture.tool("t\($0)", "Bash", ["command": "cargo test case\($0)"]) }
        lines.append(Fixture.result("t0", isError: true))
        lines.append(Fixture.result("t59", isError: true))
        let insights = scan(lines)
        #expect(insights.testRuns.count == 50)
        #expect(insights.testRuns.first?.command == "cargo test case10")
        #expect(insights.testRuns.last?.command == "cargo test case59")
        #expect(insights.testRuns.last?.outcome == .failed)
        #expect(insights.testRuns.dropLast().allSatisfy { $0.outcome == .unknown })
    }

    // MARK: Robustness and privacy

    @Test("Malformed lines, unknown types, and odd field shapes are ignored")
    func malformedAndUnknownLinesIgnored() {
        let junk = [
            "",
            "not json",
            "{",
            "[1,2,3]",
            "null",
            #"{"type":123}"#,
            #"{"type":"file-history-snapshot","snapshot":{"trackedFileBackups":{}},"isSnapshotUpdate":false}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"not a date"}"#,
            #"{"type":"assistant","message":"oops"}"#,
            #"{"type":"user","message":{"content":42}}"#,
            #"{"type":"system","subtype":"informational","content":"hello"}"#,
            #"{"type":"system","subtype":"compact_boundary","compactMetadata":"weird"}"#,
            #"{"type":"pr-link"}"#,
        ]
        #expect(scan(junk).compactions.count == 1)
        #expect(scan(Array(junk.prefix(11))) == .empty)

        // One bad block or field must not hide the valid facts beside it.
        let mixed = #"{"type":"assistant","isSidechain":"maybe","message":{"id":"m1","model":"claude-opus-4-5","usage":{"input_tokens":"lots","cache_read_input_tokens":4000},"content":[1,"x",{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/ok.swift"}},{"type":"tool_use","name":"Bash","input":"not an object"}]}}"#
        let insights = scan(junk + [mixed])
        #expect(insights.model == "claude-opus-4-5")
        #expect(insights.contextTokens == 4_000)
        #expect(insights.filesTouched == ["/p/ok.swift"])
        #expect(insights.activity?.toolName == "Bash")
    }

    /// Claude's own call descriptions, redacted commands and URL paths are
    /// kept on purpose for the activity feed; everything marked SECRET is
    /// text that must never be kept.
    @Test("No prompt, response, thinking, tool-output, or credential text survives into insights")
    func privacy() throws {
        let insights = scan([
            Fixture.user("SECRET-PROMPT please refactor", branch: "main"),
            Fixture.assistant(
                id: "msg_1",
                stopReason: "tool_use",
                usage: Fixture.usage(input: 10, read: 100),
                content: [
                    ["type": "thinking", "thinking": "SECRET-THINKING", "signature": "SECRET-SIG"],
                    ["type": "text", "text": "SECRET-RESPONSE"],
                    Fixture.toolUse("t1", "Write", ["file_path": "/p/out.swift", "content": "SECRET-CONTENT"]),
                    Fixture.toolUse("t2", "Bash", ["command": "API_KEY=SECRET-VALUE swift test", "description": "Run the suite"]),
                    Fixture.toolUse("t3", "WebFetch", ["url": "https://example.com/docs?token=SECRET-URL", "prompt": "SECRET-FETCH"]),
                    Fixture.toolUse("t4", "AskUserQuestion", ["questions": [["question": "SECRET-QUESTION"]]]),
                ]
            ),
            Fixture.user([["type": "tool_result", "tool_use_id": "t1", "content": "SECRET-OUTPUT"]]),
            Fixture.endTurn(),
        ])
        #expect(insights.filesTouched == ["/p/out.swift"])
        #expect(insights.testRuns.map(\.command) == ["swift test"])
        #expect(try !encodedText(insights).contains("SECRET"))
        #expect(insights.activities.map(\.summary) == [nil, "Run the suite", nil, nil])
        #expect(insights.activities.map(\.target) == ["/p/out.swift", "API_KEY=••• swift test", "example.com/docs", nil])
    }

    @Test("Last updated is the newest timestamp and insights round-trip through Codable")
    func lastUpdatedAndCodable() throws {
        let insights = scan([
            Fixture.assistant(id: "m1", usage: Fixture.usage(input: 5_000), second: 30),
            Fixture.tool("toolu_a", "Agent", ["description": "Scan"], second: 10),
            Fixture.compactBoundary(pre: 5_000, post: 1_000, second: 40),
            Fixture.tool("t1", "Bash", ["command": "swift test"], second: 41),
        ])
        #expect(insights.lastUpdated == Fixture.date(41))

        let decoded = try JSONDecoder().decode(TranscriptInsights.self, from: JSONEncoder().encode(insights))
        #expect(decoded == insights)
        #expect(TranscriptInsightsScanner.parseDate("2026-11-22T10:00:00Z") != nil)
        #expect(TranscriptInsightsScanner.parseDate("2026-11-22T10:00:00.123Z") != nil)
        #expect(TranscriptInsightsScanner.parseDate("yesterday") == nil)
    }
}
