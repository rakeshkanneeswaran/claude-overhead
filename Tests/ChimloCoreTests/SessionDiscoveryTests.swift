import Foundation
import Testing
@testable import ChimloCore

@Suite("Local session discovery")
struct SessionDiscoveryTests {
    @Test("Cached owner interactions do not restore without their transient options")
    func cachedOwnerInteractionsRequireLiveOptions() {
        for phase in [SessionPhase.waitingForAnswer, .waitingForApproval] {
            let restored = SessionCandidate(
                id: "claude-1",
                agent: .claude,
                title: "Create a file",
                detail: phase == .waitingForAnswer ? "Waiting for input" : "Waiting for approval",
                phase: phase,
                updatedAt: Date(timeIntervalSince1970: 100),
                evidence: .cache
            ).normalizedForCache()

            #expect(restored.phase == .working)
            #expect(restored.detail == "Working")
        }
    }

    @Test("A transcript says when Claude is running and when it is idle")
    func transcriptTurnState() throws {
        func phase(after lines: [String]) throws -> SessionPhase {
            var scanner = PrivacySafeSessionMetadataScanner()
            for line in lines { scanner.consume(line: Data(line.utf8)) }
            return try #require(scanner.candidate(
                transcriptPath: "/tmp/claude-1.jsonl",
                fallbackUpdatedAt: .distantPast
            )).phase
        }
        let prompt = #"{"sessionId":"claude-1","cwd":"/tmp/p","type":"user","message":{"role":"user","content":"Run the tests"}}"#
        let toolUse = #"{"sessionId":"claude-1","type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Running them."}]}}"#
        let endTurn = #"{"sessionId":"claude-1","type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"All green."}]}}"#
        let interrupt = #"{"sessionId":"claude-1","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#

        #expect(try phase(after: [prompt]) == .working)
        #expect(try phase(after: [prompt, toolUse]) == .working)
        #expect(try phase(after: [prompt, toolUse, endTurn]) == .completed)
        #expect(try phase(after: [prompt, toolUse, endTurn, prompt]) == .working)
        #expect(try phase(after: [prompt, toolUse, interrupt]) == .completed)

        var scanner = PrivacySafeSessionMetadataScanner()
        for line in [prompt, interrupt] { scanner.consume(line: Data(line.utf8)) }
        let candidate = try #require(scanner.candidate(transcriptPath: "/tmp/claude-1.jsonl", fallbackUpdatedAt: .distantPast))
        #expect(candidate.latestUserPrompt == "Run the tests")
    }

    @Test("Claude transcript exposes title and visible conversation previews")
    func claudeConversationPreview() throws {
        var scanner = PrivacySafeSessionMetadataScanner()
        scanner.consume(line: Data(#"{"sessionId":"claude-1","cwd":"/Users/me/Projects/overhead","timestamp":"2026-07-20T10:00:00Z","type":"user","message":{"role":"user","content":"Polish the expanded session row"}}"#.utf8))
        scanner.consume(line: Data(#"{"sessionId":"claude-1","timestamp":"2026-07-20T10:00:01Z","type":"ai-title","aiTitle":"Polish Claude Overhead expanded UI"}"#.utf8))
        scanner.consume(line: Data(#"{"sessionId":"claude-1","timestamp":"2026-07-20T10:00:02Z","type":"assistant","message":{"role":"assistant","model":"claude-sonnet","content":[{"type":"text","text":"Implemented the compact three-line layout."}]}}"#.utf8))

        let candidate = try #require(scanner.candidate(
            transcriptPath: "/Users/me/.claude/projects/overhead/claude-1.jsonl",
            fallbackUpdatedAt: .distantPast
        ))
        #expect(candidate.id == "claude-1")
        #expect(candidate.phase == .working)
        #expect(candidate.model == "claude-sonnet")
        #expect(candidate.jumpURL == nil)
        #expect(candidate.title == "Polish Claude Overhead expanded UI")
        #expect(candidate.latestUserPrompt == "Polish the expanded session row")
        #expect(candidate.latestAgentResponse == "Implemented the compact three-line layout.")
        #expect(candidate.latestConversationUpdatedAt == Date(timeIntervalSince1970: 1_784_541_602))

        let encoded = String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self)
        #expect(!encoded.contains("Polish the expanded session row"))
        #expect(!encoded.contains("Implemented the compact three-line layout."))
        #expect(!encoded.contains("claude-1.jsonl"))
    }
}
