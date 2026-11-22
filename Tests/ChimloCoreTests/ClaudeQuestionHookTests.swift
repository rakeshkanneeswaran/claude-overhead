import Foundation
import Testing
@testable import ChimloCore

@Suite("Claude question hook")
struct ClaudeQuestionHookTests {
    private let payload = Data(
        #"{"session_id":"claude-1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"tool-1","cwd":"/Users/me/Projects/overhead","transcript_path":"/private/secret.jsonl","tool_input":{"questions":[{"question":"Which target?","header":"Target","options":[{"label":"Local","description":"Run only on this Mac"},{"label":"Staging","description":"Use the shared test environment"}],"multiSelect":false}]}}"#.utf8
    )

    @Test("Question text and choices are projected without transcript context")
    func parsesQuestion() throws {
        let hook = try ClaudeQuestionHook(data: payload)

        #expect(hook.request.sessionID == "claude-1")
        #expect(hook.request.agent == .claude)
        #expect(hook.request.title == "overhead")
        #expect(hook.request.questions.first?.prompt == "Which target?")
        #expect(hook.request.questions.first?.options.map(\.label) == ["Local", "Staging"])
        #expect(hook.request.questions.first?.options.first?.detail == "Run only on this Mac")

        let encoded = try JSONEncoder().encode(hook.request)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("secret.jsonl"))
        #expect(!text.contains("tool-1"))
    }

    @Test("An explicit selection becomes Claude updated input")
    func buildsAnswerOutput() throws {
        let hook = try ClaudeQuestionHook(data: payload)
        let response = ProviderQuestionResponse(
            requestID: hook.request.id,
            outcome: .answered,
            answers: ["Which target?": "Staging"]
        )

        let output = hook.output(for: response)
        let root = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PreToolUse")
        #expect(specific["permissionDecision"] as? String == "allow")
        let updated = try #require(specific["updatedInput"] as? [String: Any])
        #expect((updated["answers"] as? [String: String])?["Which target?"] == "Staging")
        #expect((updated["questions"] as? [[String: Any]])?.count == 1)
    }

    @Test("Unavailable and invalid answers fall back to Claude Code")
    func failsBackToProvider() throws {
        let hook = try ClaudeQuestionHook(data: payload)
        #expect(hook.output(for: .unavailable(for: hook.request.id)) == ClaudeQuestionHook.fallbackOutput)
        // A typed answer is allowed (Claude Code offers "Other"), but an empty,
        // blank, oversized, or missing one is never sent.
        for invalid in ["", "   \n", String(repeating: "x", count: 1_001)] {
            #expect(hook.output(for: ProviderQuestionResponse(
                requestID: hook.request.id,
                outcome: .answered,
                answers: ["Which target?": invalid]
            )) == ClaudeQuestionHook.fallbackOutput)
        }
        #expect(hook.output(for: ProviderQuestionResponse(
            requestID: hook.request.id,
            outcome: .answered,
            answers: [:]
        )) == ClaudeQuestionHook.fallbackOutput)
    }

    @Test("A typed answer, like Claude Code's own Other, reaches Claude as written")
    func passesCustomAnswer() throws {
        let hook = try ClaudeQuestionHook(data: payload)
        let output = hook.output(for: ProviderQuestionResponse(
            requestID: hook.request.id,
            outcome: .answered,
            answers: ["Which target?": "Production, but only after the backup"]
        ))
        #expect(output != ClaudeQuestionHook.fallbackOutput)
        let root = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let updated = try #require((root["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any])
        #expect((updated["answers"] as? [String: String])?["Which target?"] == "Production, but only after the backup")
    }

    @Test("The observer ignores AskUserQuestion so it cannot clear the blocking state")
    func observerDoesNotRaceQuestionBridge() throws {
        let event = try PrivacySafeHookMapper.event(from: payload, source: .claude)
        #expect(event == nil)
    }
}
