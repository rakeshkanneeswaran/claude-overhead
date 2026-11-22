import Foundation
import Testing
@testable import ChimloCore

@Suite("Live activity from hooks")
struct HookActivityTests {
    private func detail(hook: String, tool: String? = nil) throws -> String? {
        let toolField = tool.map { #","tool_name":"\#($0)""# } ?? ""
        let payload = Data(#"{"session_id":"s-1","hook_event_name":"\#(hook)","cwd":"/tmp/app"\#(toolField)}"#.utf8)
        return try PrivacySafeHookMapper.event(from: payload, source: .claude)?.detail
    }

    @Test("A tool call names what Claude is doing right now")
    func toolActivity() throws {
        #expect(try detail(hook: "PreToolUse", tool: "Bash") == "Running a command")
        #expect(try detail(hook: "PreToolUse", tool: "Read") == "Reading files")
        #expect(try detail(hook: "PreToolUse", tool: "Edit") == "Writing files")
        #expect(try detail(hook: "PreToolUse", tool: "Grep") == "Searching")
        #expect(try detail(hook: "PreToolUse", tool: "Agent") == "Delegating to agents")
        #expect(try detail(hook: "PreToolUse", tool: "mcp__server__tool") == "Working")
    }

    @Test("Between tools and after a prompt, Claude is thinking")
    func thinking() throws {
        #expect(try detail(hook: "UserPromptSubmit") == "Thinking")
        #expect(try detail(hook: "PostToolUse", tool: "Bash") == "Thinking")
    }

    @Test("The question bridge keeps AskUserQuestion to itself")
    func questionsStayWithTheBridge() throws {
        #expect(try detail(hook: "PreToolUse", tool: "AskUserQuestion") == nil)
    }
}
