import Foundation
import Testing
@testable import ChimloCore

/// "Allow All" writes a session rule. A rule without its content covers the
/// whole tool, so a command (or a suggested rule) too long to carry must
/// never be shortened into "allow every Bash command". Through 1.0.6 it was.
@Suite("Audit 1.0.7: Allow All never grants more than the card shows")
struct Audit107AllowAllScopeTests {
    private func payload(tool: String, input: [String: Any], suggestions: [[String: Any]]? = nil) throws -> Data {
        var root: [String: Any] = [
            "session_id": "0f6c6b1e-0000-4000-8000-000000000001",
            "hook_event_name": "PermissionRequest",
            "cwd": "/Users/me/Projects/overhead",
            "tool_name": tool,
            "tool_input": input,
        ]
        if let suggestions { root["permission_suggestions"] = suggestions }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func decision(_ hook: ClaudePermissionHook, _ outcome: ProviderPermissionOutcome) throws -> [String: Any]? {
        let output = hook.output(for: ProviderPermissionResponse(requestID: hook.request.id, outcome: outcome))
        let root = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        return (root["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    }

    private func rules(_ decision: [String: Any]?) -> [[String: Any]] {
        let updates = decision?["updatedPermissions"] as? [[String: Any]] ?? []
        return updates.flatMap { $0["rules"] as? [[String: Any]] ?? [] }
    }

    @Test("An ordinary Bash command still gets a rule for exactly that command")
    func ordinaryCommandKeepsItsRule() throws {
        let hook = try ClaudePermissionHook(data: payload(tool: "Bash", input: ["command": "swift test"]))
        #expect(hook.request.allowsSessionApproval)
        let rules = rules(try decision(hook, .allowedForSession))
        #expect(rules.count == 1)
        #expect(rules.first?["toolName"] as? String == "Bash")
        #expect(rules.first?["ruleContent"] as? String == "swift test")
    }

    @Test("A Bash command too long for a rule offers no Allow All, and can never become \"allow Bash\"")
    func longCommandOffersNoAllowAll() throws {
        let long = "cat <<'EOF'\n" + String(repeating: "line of a heredoc\n", count: 400) + "EOF"
        #expect(long.utf8.count > 4_096)
        let hook = try ClaudePermissionHook(data: payload(tool: "Bash", input: ["command": long]))

        #expect(!hook.request.allowsSessionApproval)
        // Even if a response claimed "allow for session", nothing is granted.
        #expect(try decision(hook, .allowedForSession) == nil)
        // Allow Once still grants the one call, with no rule attached.
        let once = try decision(hook, .allowedOnce)
        #expect(once?["behavior"] as? String == "allow")
        #expect(once?["updatedPermissions"] == nil)
    }

    @Test("A Bash request with no command offers no Allow All")
    func missingCommandOffersNoAllowAll() throws {
        let hook = try ClaudePermissionHook(data: payload(tool: "Bash", input: ["description": "does something"]))
        #expect(!hook.request.allowsSessionApproval)
        #expect(try decision(hook, .allowedForSession) == nil)
    }

    @Test("A suggested rule whose content is too long is dropped, not widened to the whole tool")
    func oversizedSuggestionIsNotWidened() throws {
        let long = String(repeating: "x", count: 5_000)
        let hook = try ClaudePermissionHook(data: payload(
            tool: "Bash",
            input: ["command": "swift test"],
            suggestions: [[
                "type": "addRules", "behavior": "allow", "destination": "localSettings",
                "rules": [["toolName": "Bash", "ruleContent": long]],
            ]]
        ))
        // The suggestion is skipped; the fallback names exactly this command.
        let rules = rules(try decision(hook, .allowedForSession))
        #expect(rules.count == 1)
        #expect(rules.first?["ruleContent"] as? String == "swift test")
        for rule in rules where rule["toolName"] as? String == "Bash" {
            #expect(rule["ruleContent"] != nil)
        }
    }

    @Test("A suggested rule with content that is not text is dropped")
    func malformedSuggestionContentIsDropped() throws {
        let hook = try ClaudePermissionHook(data: payload(
            tool: "Bash",
            input: ["command": "swift test"],
            suggestions: [[
                "type": "addRules", "behavior": "allow", "destination": "session",
                "rules": [["toolName": "Bash", "ruleContent": ["not", "text"]]],
            ]]
        ))
        let rules = rules(try decision(hook, .allowedForSession))
        #expect(rules.first?["ruleContent"] as? String == "swift test")
    }

    @Test("Claude's own suggested rule is still used when it fits")
    func fittingSuggestionIsUsed() throws {
        let hook = try ClaudePermissionHook(data: payload(
            tool: "Bash",
            input: ["command": "swift test --filter Foo"],
            suggestions: [[
                "type": "addRules", "behavior": "allow", "destination": "localSettings",
                "rules": [["toolName": "Bash", "ruleContent": "swift test:*"]],
            ]]
        ))
        let decision = try decision(hook, .allowedForSession)
        #expect(rules(decision).first?["ruleContent"] as? String == "swift test:*")
        // Narrowed to this session, whatever Claude suggested.
        let updates = decision?["updatedPermissions"] as? [[String: Any]]
        #expect(updates?.first?["destination"] as? String == "session")
    }

    @Test("WebFetch without a readable site offers no Allow All; with one, the rule names the domain")
    func webFetchNeedsADomain() throws {
        let unreadable = try ClaudePermissionHook(data: payload(tool: "WebFetch", input: ["prompt": "read it"]))
        #expect(!unreadable.request.allowsSessionApproval)

        let readable = try ClaudePermissionHook(data: payload(tool: "WebFetch", input: ["url": "https://example.com/a/b"]))
        #expect(readable.request.allowsSessionApproval)
        #expect(rules(try decision(readable, .allowedForSession)).first?["ruleContent"] as? String == "domain:example.com")
    }
}
