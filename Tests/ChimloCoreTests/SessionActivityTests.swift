import Foundation
import Testing
@testable import ChimloCore

/// Transcript lines shaped like Claude Code's JSONL, built through
/// JSONSerialization so they stay correctly escaped.
private enum Line {
    static let project = "/Users/dev/code/app"

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func timestamp(_ second: Int) -> String {
        String(format: "2026-11-22T10:%02d:%02d.000Z", second / 60, second % 60)
    }

    static func date(_ second: Int) -> Date? {
        TranscriptInsightsScanner.parseDate(timestamp(second))
    }

    static func tool(
        _ id: String,
        _ name: String,
        _ input: [String: Any] = [:],
        second: Int = 0,
        sidechain: Bool = false,
        cwd: String? = project,
        stopReason: String = "tool_use"
    ) -> String {
        var line: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp(second),
            "isSidechain": sidechain,
            "message": [
                "id": "msg_\(id)",
                "model": "claude-opus-4-5",
                "stop_reason": stopReason,
                "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
            ] as [String: Any],
        ]
        if let cwd { line["cwd"] = cwd }
        return json(line)
    }

    static func result(_ id: String, isError: Bool? = nil, second: Int = 0, sidechain: Bool = false) -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": "OUTPUT-BODY"]
        if let isError { block["is_error"] = isError }
        return json([
            "type": "user",
            "timestamp": timestamp(second),
            "isSidechain": sidechain,
            "message": ["role": "user", "content": [block]] as [String: Any],
        ])
    }

    static func endTurn(second: Int = 0) -> String {
        json([
            "type": "assistant",
            "timestamp": timestamp(second),
            "message": [
                "id": "msg_end_\(second)",
                "model": "claude-opus-4-5",
                "stop_reason": "end_turn",
                "content": [["type": "text", "text": "All done."]],
            ] as [String: Any],
        ])
    }

    static func interrupt(second: Int = 0) -> String {
        json([
            "type": "user",
            "timestamp": timestamp(second),
            "message": ["role": "user", "content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]] as [String: Any],
        ])
    }
}

private func scan(_ lines: [String], home: String? = "/Users/dev") -> TranscriptInsights {
    var scanner = TranscriptInsightsScanner(homeDirectory: home)
    for line in lines { scanner.consume(line: Data(line.utf8)) }
    return scanner.insights
}

@Suite("Activity capture")
struct ActivityCaptureTests {
    @Test("Bash keeps Claude's own description and the command it runs")
    func bashDescriptionAndCommand() throws {
        let insights = scan([
            Line.tool("t1", "Bash", [
                "command": "cd /Users/dev/code/app && make test && git commit -m 'logo'",
                "description": "Run tests and commit the logo change locally",
            ], second: 1),
        ])
        let activity = try #require(insights.activities.first)
        #expect(activity.tool == "Bash")
        #expect(activity.kind == .executing)
        #expect(activity.summary == "Run tests and commit the logo change locally")
        #expect(activity.target == "make test && git commit -m 'logo'")
        #expect(activity.headline == "Run tests and commit the logo change locally")
        #expect(activity.status == .running)
        #expect(activity.startedAt == Line.date(1))
        #expect(activity.isTestRun)
        #expect(insights.currentTurnActivity == activity)
    }

    @Test("File tools show the path relative to the project, else under ~")
    func filePaths() {
        let insights = scan([
            Line.tool("r", "Read", ["file_path": "/Users/dev/code/app/Docs/ARCHITECTURE.md"]),
            Line.tool("w", "Write", ["file_path": "/Users/dev/code/app/Sources/ClaudeCodeMark.swift", "content": "BODY"]),
            Line.tool("e", "Edit", ["file_path": "/Users/dev/notes.md", "old_string": "OLD", "new_string": "NEW"]),
            Line.tool("n", "NotebookEdit", ["notebook_path": "/tmp/analysis.ipynb", "new_source": "CELL"]),
        ])
        #expect(insights.activities.map(\.target) == [
            "Docs/ARCHITECTURE.md", "Sources/ClaudeCodeMark.swift", "~/notes.md", "/tmp/analysis.ipynb",
        ])
        #expect(insights.activities.map(\.headline) == insights.activities.map(\.target))
        #expect(insights.activities.filter(\.targetIsPath).count == 4)
        #expect(insights.filesTouched.count == 3)
    }

    @Test("Searches, agents, the web and skills show what they act on")
    func otherTools() {
        let insights = scan([
            Line.tool("g", "Grep", ["pattern": "func consume", "path": "/Users/dev/code/app/Sources"]),
            Line.tool("g2", "Glob", ["pattern": "**/*.swift", "path": "/Users/dev/code/app/"]),
            Line.tool("a", "Agent", ["description": "Audit the scanner", "subagent_type": "Explore", "prompt": "PROMPT"]),
            Line.tool("f", "WebFetch", ["url": "https://user:pw@docs.example.com/guide/start?token=QUERY#part", "prompt": "PROMPT"]),
            Line.tool("s", "WebSearch", ["query": "swift regex lookahead"]),
            Line.tool("k", "Skill", ["skill": "code-review", "args": "ARGS"]),
            Line.tool("q", "AskUserQuestion", ["questions": [["header": "Approach", "question": "QUESTION-TEXT"]]]),
            Line.tool("m", "mcp__github__create_issue", ["title": "MCP-TITLE", "description": "MCP-DESC"]),
            Line.tool("t", "TodoWrite", ["todos": [["content": "TODO-TEXT"]]]),
        ])
        let byID = Dictionary(uniqueKeysWithValues: insights.activities.map { ($0.id, $0) })
        #expect(byID["g"]?.target == "func consume in Sources")
        #expect(byID["g2"]?.target == "**/*.swift")
        #expect(byID["a"]?.summary == "Audit the scanner")
        #expect(byID["a"]?.target == "Explore")
        #expect(byID["f"]?.target == "docs.example.com/guide/start")
        #expect(byID["s"]?.target == "swift regex lookahead")
        #expect(byID["k"]?.target == "code-review")
        #expect(byID["q"]?.target == "Approach")
        #expect(byID["m"]?.summary == nil)
        #expect(byID["m"]?.headline == "create_issue (github)")
        #expect(byID["t"]?.headline == "TodoWrite")
    }

    @Test("A call without a description falls back to its target, then its tool")
    func missingDescriptions() {
        let insights = scan([
            Line.tool("b", "Bash", ["command": "ls -la"]),
            Line.tool("x", "Bash", ["description": "   "]),
            Line.tool("y", "Bash", [:]),
        ])
        #expect(insights.activities.map(\.headline) == ["ls -la", "Bash", "Bash"])
    }

    @Test("Results complete or fail the matching call, and only that call")
    func results() {
        let insights = scan([
            Line.tool("ok", "Bash", ["command": "swift build"], second: 1),
            Line.tool("bad", "Bash", ["command": "swift test"], second: 2),
            Line.tool("open", "Read", ["file_path": "/Users/dev/code/app/a.swift"], second: 3),
            Line.result("ok", isError: false, second: 4),
            Line.result("bad", isError: true, second: 5),
        ])
        #expect(insights.activities.map(\.status) == [.completed, .failed, .running])
        #expect(insights.activities[0].finishedAt == Line.date(4))
        #expect(insights.activities[1].finishedAt == Line.date(5))
        #expect(insights.activities[2].finishedAt == nil)
    }

    @Test("A turn's end or an interrupt leaves no call running")
    func turnEndAndInterrupt() {
        let ended = scan([
            Line.tool("a", "Bash", ["command": "sleep 1"]),
            Line.endTurn(second: 2),
        ])
        #expect(ended.activities.map(\.status) == [.unknown])
        #expect(ended.currentTurnActivity == nil)

        let interrupted = scan([
            Line.tool("a", "Bash", ["command": "swift test"], second: 1),
            Line.tool("b", "Read", ["file_path": "/x"], second: 1),
            Line.result("a", isError: true, second: 2),
            Line.interrupt(second: 2),
        ])
        #expect(interrupted.activities.map(\.status) == [.failed, .unknown])
        #expect(interrupted.currentTurnActivity == nil)

        // A late result still corrects an unknown.
        let late = scan([
            Line.tool("a", "Bash", ["command": "make"]),
            Line.endTurn(second: 2),
            Line.result("a", isError: false, second: 3),
        ])
        #expect(late.activities.map(\.status) == [.completed])
    }

    @Test("Repeated lines are counted once and a result settles a call once")
    func duplicates() {
        let line = Line.tool("a", "Bash", ["command": "make", "description": "Build"], second: 1)
        let insights = scan([
            line, line,
            Line.result("a", isError: true, second: 2),
            Line.result("a", isError: false, second: 3),
        ])
        #expect(insights.activities.count == 1)
        #expect(insights.activities[0].status == .failed)
        #expect(insights.activities[0].finishedAt == Line.date(2))
    }

    @Test("Out-of-order lines: results before calls, and calls stay in start order")
    func outOfOrder() {
        let insights = scan([
            Line.result("late", isError: false, second: 9),
            Line.tool("b", "Bash", ["command": "second"], second: 5),
            Line.tool("a", "Bash", ["command": "first"], second: 2),
            Line.tool("late", "Bash", ["command": "third"], second: 8),
        ])
        #expect(insights.activities.map(\.id) == ["a", "b", "late"])
        #expect(insights.activities.last?.status == .completed)
        #expect(insights.activities.last?.finishedAt == Line.date(9))
    }

    @Test("Subagent lines never enter the session's own feed")
    func sidechainSkipped() {
        let insights = scan([
            Line.tool("main", "Agent", ["description": "Explore"], second: 1),
            Line.tool("sub", "Bash", ["command": "grep -r x"], second: 2, sidechain: true),
            Line.result("sub", isError: false, second: 3, sidechain: true),
        ])
        #expect(insights.activities.map(\.id) == ["main"])
    }

    @Test("Malformed lines are ignored without losing the calls beside them")
    func malformed() {
        let insights = scan([
            "", "not json", "{", "[1,2]", "null",
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":"oops"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#,
            Line.tool("ok", "Read", ["file_path": "/Users/dev/code/app/b.swift"]),
        ])
        #expect(insights.activities.map(\.tool) == ["Bash", "Read"])
        #expect(insights.activities.first?.id.hasPrefix("unidentified-") == true)
    }

    @Test("The feed is bounded, keeping the newest calls")
    func bounded() {
        let count = TranscriptInsightsScanner.maximumActivities + 30
        let lines = (0..<count).map { Line.tool("t\($0)", "Bash", ["command": "echo \($0)"], second: $0) }
        let insights = scan(lines)
        #expect(insights.activities.count == TranscriptInsightsScanner.maximumActivities)
        #expect(insights.activities.first?.id == "t30")
        #expect(insights.activities.last?.id == "t\(count - 1)")
    }

    @Test("Each session's scanner keeps its own feed")
    func isolation() {
        var first = TranscriptInsightsScanner(homeDirectory: nil)
        var second = TranscriptInsightsScanner(homeDirectory: nil)
        first.consume(line: Data(Line.tool("same-id", "Bash", ["command": "one"]).utf8))
        second.consume(line: Data(Line.tool("same-id", "Bash", ["command": "two"]).utf8))
        second.consume(line: Data(Line.result("same-id", isError: true).utf8))
        #expect(first.insights.activities.map(\.target) == ["one"])
        #expect(first.insights.activities.map(\.status) == [.running])
        #expect(second.insights.activities.map(\.status) == [.failed])
    }

    @Test("Reading a transcript in pieces gives the same feed as reading it whole")
    func incrementalMatchesBatch() {
        let lines = [
            Line.tool("a", "Bash", ["command": "make", "description": "Build"], second: 1),
            Line.result("a", isError: false, second: 2),
            Line.tool("b", "Edit", ["file_path": "/Users/dev/code/app/x.swift"], second: 3),
            Line.endTurn(second: 4),
        ]
        let whole = scan(lines)
        var scanner = TranscriptInsightsScanner(homeDirectory: "/Users/dev")
        for line in lines {
            scanner.consume(line: Data(line.utf8))
            _ = scanner.insights
        }
        #expect(scanner.insights == whole)
        #expect(whole.activities.map(\.status) == [.completed, .unknown])
    }

    @Test("No output, prompt, file content or question text reaches the feed")
    func privacy() throws {
        let insights = scan([
            Line.tool("w", "Write", ["file_path": "/Users/dev/code/app/a.swift", "content": "SECRET-CONTENT"]),
            Line.tool("a", "Agent", ["description": "Explore", "prompt": "SECRET-PROMPT"]),
            Line.tool("f", "WebFetch", ["url": "https://x.dev/p?key=SECRET-QUERY", "prompt": "SECRET-FETCH"]),
            Line.tool("q", "AskUserQuestion", ["questions": [["header": "Pick", "question": "SECRET-QUESTION"]]]),
            Line.tool("b", "Bash", ["command": "API_TOKEN=SECRET-VALUE ./deploy.sh"]),
            Line.result("w", isError: false),
        ])
        let encoded = String(decoding: try JSONEncoder().encode(insights.activities), as: UTF8.self)
        #expect(!encoded.contains("SECRET"))
        #expect(!encoded.contains("OUTPUT-BODY"))
        #expect(insights.activities.last?.target == "API_TOKEN=••• ./deploy.sh")
    }

    @Test("Reading thousands of lines stays fast and bounded")
    func performance() {
        let lines = (0..<6_000).flatMap { index in
            [
                Line.tool("t\(index)", "Bash", ["command": "swift test --filter Case\(index)", "description": "Run case \(index)"], second: index % 3_600),
                Line.result("t\(index)", isError: index.isMultiple(of: 7), second: index % 3_600),
            ]
        }.map { Data($0.utf8) }
        let clock = ContinuousClock()
        var scanner = TranscriptInsightsScanner(homeDirectory: nil)
        let elapsed = clock.measure {
            for line in lines { scanner.consume(line: line) }
        }
        #expect(scanner.insights.activities.count == TranscriptInsightsScanner.maximumActivities)
        // Generous for a loaded CI machine; typical runs take a fraction.
        #expect(elapsed < .seconds(10))
    }
}

@Suite("Activity text")
struct ActivityTextTests {
    @Test("Commands lose secrets, a leading cd, and everything after the first line")
    func commandRedaction() {
        // Fake credentials, assembled at runtime so no credential-shaped
        // literal sits in the source for secret scanners to flag.
        let anthropicKey = "sk-" + "ant-api03-" + "abcdefghijklmnop"
        let githubToken = "ghp" + "_" + "abcdefghijklmnopqrstuvwxyz0123"
        let openAIKey = "sk-" + "proj-" + "abcdefghijklmnopqrstu"
        let awsKeyID = "AKIA" + "ABCDEFGHIJKLMNOP"
        let mixedSecret = "Qm9vbGVhbkZsYWdz" + "V2l0aE1peGVkQ2FzZTEyMw9z"
        let cases: [(String, String)] = [
            ("GITHUB_TOKEN=abc123 gh pr list", "GITHUB_TOKEN=••• gh pr list"),
            ("curl -H 'Authorization: Bearer \(anthropicKey)' https://api.x.dev", "curl -H 'Authorization: •••' https://api.x.dev"),
            ("curl -H \"Bearer abcdef1234567890xyz\" x", "curl -H \"Bearer •••\" x"),
            ("git push https://me:hunter2@github.com/o/r.git", "git push https://•••@github.com/o/r.git"),
            ("gh auth login --with-token \(githubToken)", "gh auth login --with-token •••"),
            ("deploy --token s3cr3t --env prod", "deploy --token ••• --env prod"),
            ("deploy --password='p w' now", "deploy --password=••• now"),
            ("export OPENAI=\(openAIKey)", "export OPENAI=•••"),
            ("aws s3 ls \(awsKeyID)", "aws s3 ls •••"),
            ("echo \(mixedSecret)", "echo •••"),
            ("cd \"/Users/dev/my app\" && swift test", "swift test"),
            ("cd /x; make", "make"),
            // Paths and shell references are not credentials; secret names
            // lose their value whatever it looks like.
            ("S=/private/tmp/x; L=$S/live; ls $L", "S=/private/tmp/x; L=$S/live; ls $L"),
            ("PGPASSWORD=/weird psql", "PGPASSWORD=••• psql"),
            ("X=hunter2 run", "X=••• run"),
            ("TOKEN=\"$(cat ~/.t)\" run", "TOKEN=••• run"),
            ("git commit -m \"$(cat <<'EOF'\nSECRET BODY\nEOF\n)\"", "git commit -m \"$(cat <<'EOF'"),
        ]
        for (raw, expected) in cases {
            #expect(ActivityText.command(raw) == expected, "\(raw)")
        }
    }

    @Test("Harmless text survives redaction untouched")
    func harmlessText() {
        let unchanged = [
            "git checkout 4792d1d9f0e6c1a2b3c4d5e6f7a8b9c0d1e2f3a4",
            "ls /private/tmp/claude-501/-Users-rakesh-Documents-repositories-claude-overhead",
            "swift test --filter SessionActivityTests",
            "git log --pretty=format:%h --since=2.weeks",
            "grep -rn \"token\" Sources",
        ]
        for text in unchanged {
            #expect(ActivityText.command(text) == text, "\(text)")
        }
        #expect(ActivityText.singleLine("Add basic validation for the token field") == "Add basic validation for the token field")
    }

    @Test("Text is one bounded line; paths keep their end")
    func bounds() throws {
        #expect(ActivityText.singleLine("  Run\n the   tests ") == "Run the tests")
        #expect(ActivityText.singleLine("   ") == nil)
        #expect(ActivityText.command("\n\n  \n") == nil)
        let long = try #require(ActivityText.command("echo " + String(repeating: "a ", count: 300)))
        #expect(long.count == ActivityText.maximumCharacters)
        #expect(long.hasSuffix("…"))
        let path = try #require(ActivityText.path(
            "/Users/dev/" + String(repeating: "deep/", count: 60) + "File.swift",
            workingDirectory: nil,
            home: "/Users/dev"
        ))
        #expect(path.count == ActivityText.maximumCharacters)
        #expect(path.hasPrefix("…"))
        #expect(path.hasSuffix("File.swift"))
        #expect(ActivityText.path("/a\n/b", workingDirectory: nil, home: nil) == nil)
        #expect(ActivityText.url("not a url") == nil)
        #expect(ActivityText.url("https://x.dev/") == "x.dev")
    }

    @Test("MCP tool names read as tool and server")
    func toolNames() {
        #expect(SessionActivity(id: "1", tool: "mcp__github__create_issue").toolDisplayName == "create_issue (github)")
        #expect(SessionActivity(id: "1", tool: "mcp__claude_ai_Claude_Docs__batch").toolDisplayName == "batch (Claude Docs)")
        #expect(SessionActivity(id: "1", tool: "mcp__broken").toolDisplayName == "mcp__broken")
        #expect(SessionActivity(id: "1", tool: "Bash").toolDisplayName == "Bash")
    }
}

@Suite("Session lifecycle")
struct SessionLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        _ phase: SessionPhase,
        ageMinutes: Double,
        live: String? = nil,
        owner: Bool = false
    ) -> SessionRunState {
        SessionRunState.classify(
            phase: phase,
            hasOwnerInteraction: owner,
            updatedAt: now.addingTimeInterval(-ageMinutes * 60),
            liveStatus: live,
            now: now
        )
    }

    @Test("Permissions and questions outrank everything")
    func ownerFirst() {
        #expect(state(.working, ageMinutes: 0, live: "busy", owner: true) == .needsYou)
        #expect(state(.waitingForApproval, ageMinutes: 90) == .needsYou)
        #expect(state(.waitingForAnswer, ageMinutes: 0) == .needsYou)
    }

    @Test("Working is believed only while evidence is fresh")
    func staleWorkIsNotRunning() {
        #expect(state(.working, ageMinutes: 1) == .running)
        #expect(state(.working, ageMinutes: 19) == .running)
        #expect(state(.working, ageMinutes: 25) == .older)
        // Claude Code's own report wins in both directions.
        #expect(state(.working, ageMinutes: 45, live: "busy") == .running)
        #expect(state(.working, ageMinutes: 5, live: "idle") == .waitingInput)
        // An idle report lagging a fresh turn does not stop it.
        #expect(state(.working, ageMinutes: 0.5, live: "idle") == .running)
    }

    @Test("Finished sessions wait for input while open, else age out")
    func finished() {
        #expect(state(.completed, ageMinutes: 50, live: "idle") == .waitingInput)
        #expect(state(.completed, ageMinutes: 5) == .recentlyCompleted)
        #expect(state(.completed, ageMinutes: 31) == .older)
        #expect(state(.failed, ageMinutes: 5) == .failed)
        #expect(state(.failed, ageMinutes: 31) == .older)
    }

    @Test("A running call in a stopped session reads as unknown")
    func presentedStatus() {
        let running = SessionActivity(id: "a", tool: "Bash", status: .running)
        #expect(running.presentedStatus(sessionIsWorking: true) == .running)
        #expect(running.presentedStatus(sessionIsWorking: false) == .unknown)
        let done = SessionActivity(id: "b", tool: "Bash", status: .completed)
        #expect(done.presentedStatus(sessionIsWorking: false) == .completed)
    }

    @Test("Sessions order by state, then newest, then id")
    func ordering() {
        let t = now
        let entries: [SessionOrdering.Entry] = [
            .init(id: "old", state: .older, updatedAt: t),
            .init(id: "done", state: .recentlyCompleted, updatedAt: t),
            .init(id: "run-old", state: .running, updatedAt: t.addingTimeInterval(-60)),
            .init(id: "wait", state: .waitingInput, updatedAt: t),
            .init(id: "ask", state: .needsYou, updatedAt: t.addingTimeInterval(-600)),
            .init(id: "run-new", state: .running, updatedAt: t),
            .init(id: "fail", state: .failed, updatedAt: t),
            .init(id: "run-b", state: .running, updatedAt: t),
        ]
        #expect(SessionOrdering.ordered(entries).map(\.id) == [
            "ask", "fail", "run-b", "run-new", "run-old", "wait", "done", "old",
        ])
    }

    @Test("The closed notch follows the owner's attention, then the selection, then the newest work")
    func focus() {
        let t = now
        let running: [NotchActivityFocus.Candidate] = [
            .init(id: "a", state: .running, updatedAt: t.addingTimeInterval(-30)),
            .init(id: "b", state: .running, updatedAt: t),
            .init(id: "c", state: .recentlyCompleted, updatedAt: t),
        ]
        #expect(NotchActivityFocus.sessionID(among: running, selected: nil) == "b")
        #expect(NotchActivityFocus.sessionID(among: running, selected: "a") == "a")
        // A selected session that is not running does not hold the notch.
        #expect(NotchActivityFocus.sessionID(among: running, selected: "c") == "b")
        let asking = running + [.init(id: "q", state: .needsYou, updatedAt: t.addingTimeInterval(-900))]
        #expect(NotchActivityFocus.sessionID(among: asking, selected: "a") == "q")
        #expect(NotchActivityFocus.sessionID(among: [running[2]], selected: nil) == nil)
    }

    @Test("The compact line puts permission first and never invents activity")
    func compactLine() {
        let latest = SessionActivity(id: "a", tool: "Bash", summary: "Run tests", target: "swift test")
        let permission = CompactActivityLine.make(
            permissionTool: "Bash", hasQuestion: true, latest: latest, isWorking: true, fallback: "Working"
        )
        #expect(permission.tone == .attention)
        #expect(permission.text == "Needs your permission")
        #expect(permission.tool == "Bash")

        let question = CompactActivityLine.make(
            permissionTool: nil, hasQuestion: true, latest: latest, isWorking: true, fallback: "Working"
        )
        #expect(question.tone == .attention)

        let working = CompactActivityLine.make(
            permissionTool: nil, hasQuestion: false, latest: latest, isWorking: true, fallback: "Running a command"
        )
        #expect(working.tool == "Bash")
        #expect(working.text == "Run tests")
        #expect(working.tone == .working)

        let unknown = CompactActivityLine.make(
            permissionTool: nil, hasQuestion: false, latest: nil, isWorking: true, fallback: "Running a command"
        )
        #expect(unknown.tool == nil)
        #expect(unknown.text == "Running a command")

        let idle = CompactActivityLine.make(
            permissionTool: nil, hasQuestion: false, latest: latest, isWorking: false, fallback: "Finished"
        )
        #expect(idle.tool == nil)
        #expect(idle.text == "Finished")
        #expect(idle.tone == .quiet)

        let file = SessionActivity(id: "w", tool: "Write", target: "Sources/ClaudeCodeMark.swift")
        let path = CompactActivityLine.make(
            permissionTool: nil, hasQuestion: false, latest: file, isWorking: true, fallback: "Working"
        )
        #expect(path.truncatesMiddle)
        #expect(path.text == "Sources/ClaudeCodeMark.swift")
    }
}

@Suite("Owner interaction lifetime")
struct OwnerInteractionLifetimeTests {
    @Test("Only the session ending closes an open request; turns, tools and subagents never do")
    func onlySessionEndCloses() {
        #expect(OwnerInteractionLifetime.endsPendingRequests(.sessionEnded))
        // A background subagent can still be waiting on a real permission
        // while the main agent stops (completed also covers SubagentStop),
        // the owner types a new prompt (activity), or a parallel tool reports.
        let neverClose: [AgentEventKind] = [
            .sessionStarted, .activity, .completed, .failed,
            .permissionRequested, .permissionResolved, .questionRequested, .questionResolved,
        ]
        for kind in neverClose {
            #expect(!OwnerInteractionLifetime.endsPendingRequests(kind), "\(kind)")
        }
    }
}
