import Foundation
import Testing
@testable import ChimloCore

/// A Write or Edit of a large file reaches the helper as a hook payload far
/// over 64 KB. It must still become a card in the notch; before, the helper
/// printed `{}` and the notch showed nothing while Claude Code waited.
@Suite("Audit 107: large blocking hook payloads")
struct Audit107TransportHookCapTests {
    @Test("A Write of a 1 MB file still becomes a permission request, with a clipped preview")
    func largeWriteBecomesARequest() throws {
        let content = String(repeating: "let value = \"x\"\n", count: 65_536)
        let payload = try permissionPayload(tool: "Write", input: [
            "file_path": "/Users/me/Projects/overhead/Generated.swift",
            "content": content,
        ])
        #expect(payload.count > 1_024 * 1_024)

        let hook = try ClaudePermissionHook(data: payload)

        #expect(hook.request.prompt == "Do you want Claude to write Generated.swift?")
        #expect(hook.request.detail == "/Users/me/Projects/overhead/Generated.swift")
        #expect(hook.request.preview?.hasPrefix("let value = \"x\"\n") == true)
        #expect(hook.request.preview?.hasSuffix("… preview clipped") == true)
        #expect((hook.request.preview ?? "").utf8.count <= 4_096 + 32)
        #expect(hook.asksOwner)
    }

    @Test("A large Edit shows the start of what changes, and Allow Once grants only that call")
    func largeEditBecomesARequest() throws {
        let payload = try permissionPayload(tool: "Edit", input: [
            "file_path": "/Users/me/Projects/overhead/Big.swift",
            "old_string": String(repeating: "old line\n", count: 40_000),
            "new_string": String(repeating: "new line\n", count: 40_000),
        ])
        #expect(payload.count > 512 * 1_024)

        let hook = try ClaudePermissionHook(data: payload)
        let output = hook.output(for: ProviderPermissionResponse(requestID: hook.request.id, outcome: .allowedOnce))
        let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])

        #expect(hook.request.prompt == "Do you want Claude to edit Big.swift?")
        #expect(hook.request.preview?.hasPrefix("Before\nold line") == true)
        #expect(decision["behavior"] as? String == "allow")
        #expect(decision["updatedPermissions"] == nil)
        // Without an explicit choice a large payload still grants nothing.
        let unanswered = hook.output(for: .unavailable(for: hook.request.id))
        #expect(unanswered == ClaudePermissionHook.fallbackOutput)
    }

    @Test("Input beyond the limit is still refused")
    func oversizedInputIsRefused() {
        let tooLarge = Data(count: ClaudePermissionHook.maximumPayloadBytes + 1)
        #expect(throws: ClaudePermissionHookError.self) { _ = try ClaudePermissionHook(data: tooLarge) }
        let tooLargeQuestion = Data(count: ClaudeQuestionHook.maximumPayloadBytes + 1)
        #expect(throws: ClaudeQuestionHookError.self) { _ = try ClaudeQuestionHook(data: tooLargeQuestion) }
    }

    @Test("A question with very long option descriptions is still asked, and echoed back unchanged")
    func largeQuestionIsEchoedUnchanged() throws {
        let longDescription = String(repeating: "details ", count: 4_000)
        let questions: [[String: Any]] = [[
            "question": "Which target?",
            "header": "Target",
            "multiSelect": false,
            "options": [
                ["label": "Local", "description": longDescription],
                ["label": "Staging", "description": longDescription],
                ["label": "Production", "description": longDescription],
            ],
        ]]
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-1",
            "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion",
            "cwd": "/Users/me/Projects/overhead",
            "tool_input": ["questions": questions],
        ])
        #expect(payload.count > 64 * 1_024)

        let hook = try ClaudeQuestionHook(data: payload)
        let output = hook.output(for: ProviderQuestionResponse(
            requestID: hook.request.id, outcome: .answered, answers: ["Which target?": "Local"]
        ))
        let root = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        let updated = try #require(specific["updatedInput"] as? [String: Any])
        let echoed = try #require(updated["questions"] as? [[String: Any]])
        let options = try #require(echoed.first?["options"] as? [[String: Any]])

        // The card drops a description too long to show; Claude gets it back whole.
        #expect(hook.request.questions.first?.options.first?.detail == nil)
        #expect(options.first?["description"] as? String == longDescription)
        #expect((updated["answers"] as? [String: String]) == ["Which target?": "Local"])
    }

    private func permissionPayload(tool: String, input: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-1",
            "hook_event_name": "PermissionRequest",
            "tool_name": tool,
            "cwd": "/Users/me/Projects/overhead",
            "permission_mode": "default",
            "tool_input": input,
        ])
    }
}
