import Foundation
import Testing
@testable import ChimloCore

/// "Allow All" writes a rule for the rest of the session, so it must never
/// reach further than the card the owner is looking at, and the card must say
/// how far it reaches. Through 1.0.8 a Read card could allow every read, a
/// Bash card could switch the session to accept-edits, and a suggestion could
/// carry rules for tools the card did not show.
@Suite("Allow All: no wider than the card")
struct AllowAllScopeTests {
    private static func hook(tool: String, input: String, suggestions: String? = nil) throws -> ClaudePermissionHook {
        let suggestionsField = suggestions.map { #","permission_suggestions":\#($0)"# } ?? ""
        let json = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":\#(input)\#(suggestionsField)}"#
        return try ClaudePermissionHook(data: Data(json.utf8))
    }

    /// The single permission update "Allow All" would send, if any.
    private static func update(_ hook: ClaudePermissionHook) throws -> [String: Any]? {
        guard hook.request.allowsSessionApproval else { return nil }
        let output = hook.output(for: ProviderPermissionResponse(requestID: hook.request.id, outcome: .allowedForSession))
        let root = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        return (decision["updatedPermissions"] as? [[String: Any]])?.first
    }

    private static func rules(_ update: [String: Any]?) -> [[String: String]] {
        (update?["rules"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
    }

    @Test("A card that names a file, a pattern or an address has no Allow All without a rule that names it too")
    func targetedCardsNeedARule() throws {
        for (tool, input) in [
            ("Read", #"{"file_path":"/other/README.md"}"#),
            ("Glob", #"{"pattern":"**/*.swift"}"#),
            ("Grep", #"{"pattern":"TODO","path":"/work"}"#),
            ("NotebookRead", #"{"notebook_path":"/work/a.ipynb"}"#),
            ("mcp__files__read_file", #"{"path":"/etc/hosts"}"#),
            ("mcp__shell__run", #"{"command":"ls"}"#),
        ] {
            let hook = try Self.hook(tool: tool, input: input)
            #expect(!hook.request.allowsSessionApproval, "\(tool)")
            #expect(hook.request.sessionApprovalScope == nil, "\(tool)")
            // Asked anyway, it grants nothing.
            let output = hook.output(for: ProviderPermissionResponse(requestID: hook.request.id, outcome: .allowedForSession))
            #expect(output == ClaudePermissionHook.fallbackOutput, "\(tool)")
        }
    }

    @Test("Claude's own rule for the file on the card is taken, narrowed to the session")
    func suggestedRuleForTheCard() throws {
        let hook = try Self.hook(
            tool: "Read",
            input: #"{"file_path":"/other/docs/README.md"}"#,
            suggestions: #"[{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"//other/docs/**"}],"behavior":"allow","destination":"localSettings"}]"#
        )
        let update = try #require(try Self.update(hook))
        #expect(Self.rules(update) == [["toolName": "Read", "ruleContent": "//other/docs/**"]])
        #expect(update["destination"] as? String == "session")
        #expect(hook.request.sessionApprovalScope == "Read(//other/docs/**) in this session")
    }

    @Test("A suggested rule for the whole tool is not taken when the card names one file")
    func wholeToolRuleRefused() throws {
        let hook = try Self.hook(
            tool: "Read",
            input: #"{"file_path":"/other/README.md"}"#,
            suggestions: #"[{"type":"addRules","rules":[{"toolName":"Read"}],"behavior":"allow","destination":"session"}]"#
        )
        #expect(!hook.request.allowsSessionApproval)
    }

    @Test("A suggestion that also covers a tool the card does not show is not taken")
    func otherToolsRefused() throws {
        let suggestions = #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"},{"toolName":"Read"}],"behavior":"allow","destination":"session"}]"#
        let hook = try Self.hook(tool: "Bash", input: #"{"command":"npm test"}"#, suggestions: suggestions)
        // It falls back to a rule for exactly the command on the card.
        let update = try #require(try Self.update(hook))
        #expect(Self.rules(update) == [["toolName": "Bash", "ruleContent": "npm test"]])
        #expect(hook.request.sessionApprovalScope == "Bash(npm test) in this session")

        // A rule for another tool alone is no better.
        let unrelated = try Self.hook(
            tool: "WebSearch",
            input: #"{"query":"swift"}"#,
            suggestions: #"[{"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"session"}]"#
        )
        #expect(Self.rules(try Self.update(unrelated)) == [["toolName": "WebSearch"]])
    }

    @Test("Only a file-edit card can switch the session to accept edits")
    func acceptEditsOnlyForEdits() throws {
        let suggestion = #"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#
        // On a command card the suggestion is ignored; the command rule is used.
        let bash = try Self.hook(tool: "Bash", input: #"{"command":"make build"}"#, suggestions: suggestion)
        let bashUpdate = try #require(try Self.update(bash))
        #expect(bashUpdate["type"] as? String == "addRules")
        #expect(Self.rules(bashUpdate) == [["toolName": "Bash", "ruleContent": "make build"]])
        // On a read card there is then nothing to offer.
        let read = try Self.hook(tool: "Read", input: #"{"file_path":"/a"}"#, suggestions: suggestion)
        #expect(!read.request.allowsSessionApproval)

        // On an edit card it is what Allow All means, and the card says so.
        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"] {
            let edit = try Self.hook(tool: tool, input: #"{"file_path":"/work/a.txt","content":"x"}"#, suggestions: suggestion)
            let update = try #require(try Self.update(edit))
            #expect(update["type"] as? String == "setMode", "\(tool)")
            #expect(update["mode"] as? String == "acceptEdits", "\(tool)")
            #expect(edit.request.sessionApprovalScope == "every file edit in this session", "\(tool)")
        }
        // Bypass is never forwarded, whatever suggests it.
        let bypass = try Self.hook(
            tool: "Write",
            input: #"{"file_path":"/work/a.txt","content":"x"}"#,
            suggestions: #"[{"type":"setMode","mode":"bypassPermissions","destination":"session"}]"#
        )
        #expect(try Self.update(bypass)?["mode"] as? String == "acceptEdits")
    }

    @Test("A tool with no command, file or address may be allowed as a whole, and the card says it is the whole tool")
    func wholeToolWhereThatIsTheTool() throws {
        let search = try Self.hook(tool: "WebSearch", input: #"{"query":"swift concurrency"}"#)
        #expect(Self.rules(try Self.update(search)) == [["toolName": "WebSearch"]])
        #expect(search.request.sessionApprovalScope == "every use of WebSearch in this session")

        let tool = try Self.hook(tool: "mcp__calendar__list_events", input: #"{"day":"today"}"#)
        #expect(Self.rules(try Self.update(tool)) == [["toolName": "mcp__calendar__list_events"]])
        #expect(tool.request.sessionApprovalScope == "every use of mcp__calendar__list_events in this session")
    }

    @Test("A web fetch is allowed for its site only")
    func webFetchDomain() throws {
        let hook = try Self.hook(tool: "WebFetch", input: #"{"url":"https://example.com/docs","prompt":"read"}"#)
        #expect(Self.rules(try Self.update(hook)) == [["toolName": "WebFetch", "ruleContent": "domain:example.com"]])
        #expect(hook.request.sessionApprovalScope == "WebFetch(domain:example.com) in this session")
    }

    @Test("A long scope is clipped, and a request from an older helper has none")
    func scopeText() throws {
        let command = String(repeating: "a", count: 600)
        let hook = try Self.hook(tool: "Bash", input: #"{"command":"\#(command)"}"#)
        let scope = try #require(hook.request.sessionApprovalScope)
        #expect(scope.count == 240)
        #expect(scope.hasSuffix("…"))

        let older = try JSONDecoder().decode(ProviderPermissionRequest.self, from: Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sessionID":"s","agent":"claude","title":"t","toolName":"Bash","prompt":"p","allowsSessionApproval":true}"#.utf8
        ))
        #expect(older.sessionApprovalScope == nil)
        // The scope survives the wire.
        let sent = try JSONDecoder().decode(ProviderPermissionRequest.self, from: JSONEncoder().encode(hook.request))
        #expect(sent.sessionApprovalScope == scope)
    }

    @Test("The card's height makes room for the scope line")
    func cardHeight() {
        let without = SessionInteractionLayout.permissionRowHeight(promptLineCount: 1, detailLineCount: nil, previewLineCount: 2)
        let oneLine = SessionInteractionLayout.permissionRowHeight(
            promptLineCount: 1, detailLineCount: nil, previewLineCount: 2, scopeLineCount: 1
        )
        let twoLines = SessionInteractionLayout.permissionRowHeight(
            promptLineCount: 1, detailLineCount: nil, previewLineCount: 2, scopeLineCount: 2
        )
        #expect(oneLine == without + 12 + 9)
        #expect(twoLines == oneLine + 12)
    }
}
