import Foundation

public enum ClaudePermissionHookError: Error, LocalizedError, Sendable {
    case payloadTooLarge
    case malformedPayload
    case unsupportedEvent
    case invalidPermission

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge: "Claude permission payload exceeds the local safety limit"
        case .malformedPayload: "Claude permission payload is not valid JSON"
        case .unsupportedEvent: "Claude hook is not a PermissionRequest event"
        case .invalidPermission: "Claude permission payload is incomplete or out of bounds"
        }
    }
}

/// Holds the minimum transient context needed to show and resolve one Claude
/// Code permission prompt. Tool input and permission rules live only for this
/// blocking helper invocation and are never written to Claude Overhead's session store.
public struct ClaudePermissionHook: Sendable {
    /// How much hook input is read. Claude Code sends the whole tool input,
    /// so a Write or Edit of a large file is far bigger than the request
    /// built from it: every field kept is capped and the preview is clipped,
    /// which is what keeps the request inside one protocol frame.
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024
    public static let fallbackOutput = Data("{}\n".utf8)

    public let request: ProviderPermissionRequest
    /// Claude Code's `permission_mode`: "default" (shown as Manual), "plan",
    /// "acceptEdits", "auto", "dontAsk" or "bypassPermissions". Absent from
    /// older Claude Code versions.
    public let permissionMode: String?
    private let sessionPermissionUpdateJSON: Data?

    /// Modes where the owner chose never to be asked. Claude Code still runs
    /// PermissionRequest where it would otherwise deny without asking, so in
    /// these the notch stays out of it and Claude Code does what the mode says.
    public static let modesThatNeverAsk: Set<String> = ["dontAsk", "bypassPermissions"]

    /// Whether this request may be shown in the notch at all. An unknown or
    /// missing mode asks, the same as Claude Code's own prompt would.
    public var asksOwner: Bool {
        guard let permissionMode else { return true }
        return !Self.modesThatNeverAsk.contains(permissionMode)
    }

    /// `isUnattended` is what `ClaudeLaunch` found about the Claude Code
    /// process that ran this hook; the app decides what to do with it.
    public init(data: Data, expiresAt: Date? = nil, isUnattended: Bool = false) throws {
        guard data.count <= Self.maximumPayloadBytes else {
            throw ClaudePermissionHookError.payloadTooLarge
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = Self.boundedString(root["hook_event_name"], maximumBytes: 64),
              let toolName = Self.boundedString(root["tool_name"], maximumBytes: 256) else {
            throw ClaudePermissionHookError.malformedPayload
        }
        guard eventName == "PermissionRequest" else {
            throw ClaudePermissionHookError.unsupportedEvent
        }
        guard let rawSessionID = Self.boundedString(root["session_id"], maximumBytes: 512),
              let toolInput = root["tool_input"] as? [String: Any] else {
            throw ClaudePermissionHookError.invalidPermission
        }
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { throw ClaudePermissionHookError.invalidPermission }

        permissionMode = Self.optionalBoundedString(root["permission_mode"], maximumBytes: 64)
        let cwd = Self.optionalBoundedString(root["cwd"], maximumBytes: 4_096)
        let projectName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
        let presentation = Self.presentation(toolName: toolName, toolInput: toolInput)
        let sessionPermissionUpdate = Self.sessionPermissionUpdate(
            from: root["permission_suggestions"],
            currentToolName: toolName,
            toolInput: toolInput
        )

        request = ProviderPermissionRequest(
            sessionID: sessionID,
            agent: .claude,
            title: projectName ?? "Claude Code session",
            toolName: toolName,
            prompt: presentation.prompt,
            detail: presentation.detail,
            preview: presentation.preview,
            // "Allow All" is offered only when a rule exists that grants
            // what the card shows and no more.
            allowsSessionApproval: sessionPermissionUpdate != nil,
            expiresAt: expiresAt,
            permissionMode: permissionMode,
            isUnattended: isUnattended,
            sessionApprovalScope: sessionPermissionUpdate.map(Self.scopeSummary(of:))
        )
        sessionPermissionUpdateJSON = try sessionPermissionUpdate.map {
            try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }
    }

    public func output(for response: ProviderPermissionResponse) -> Data {
        guard response.requestID == request.id else { return Self.fallbackOutput }

        let decision: [String: Any]
        switch response.outcome {
        case .allowedOnce:
            decision = ["behavior": "allow"]
        case .allowedForSession:
            guard request.allowsSessionApproval,
                  let sessionPermissionUpdateJSON,
                  let update = try? JSONSerialization.jsonObject(with: sessionPermissionUpdateJSON)
            else { return Self.fallbackOutput }
            decision = [
                "behavior": "allow",
                "updatedPermissions": [update],
            ]
        case .denied:
            decision = [
                "behavior": "deny",
                "message": "Denied in Claude Overhead",
                "interrupt": false,
            ]
        case .cancelled, .unavailable:
            return Self.fallbackOutput
        }

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return Self.fallbackOutput }
        return data + Data("\n".utf8)
    }

    private static func presentation(
        toolName: String,
        toolInput: [String: Any]
    ) -> (prompt: String, detail: String?, preview: String?) {
        let path = optionalBoundedString(toolInput["file_path"], maximumBytes: 4_096)
            ?? optionalBoundedString(toolInput["notebook_path"], maximumBytes: 4_096)
        let filename = path.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
        let description = optionalBoundedString(toolInput["description"], maximumBytes: 1_024)

        switch toolName {
        case "Write":
            return (
                "Do you want Claude to write \(filename ?? "this file")?",
                path,
                boundedPreview(toolInput["content"] as? String)
            )
        case "Edit", "MultiEdit":
            let before = toolInput["old_string"] as? String
            let after = toolInput["new_string"] as? String
            let preview = switch (before, after) {
            case let (.some(before), .some(after)):
                boundedPreview("Before\n\(before)\n\nAfter\n\(after)")
            case (_, .some(let after)):
                boundedPreview(after)
            default:
                prettyPrintedPreview(toolInput)
            }
            return (
                "Do you want Claude to edit \(filename ?? "this file")?",
                path,
                preview
            )
        case "Bash":
            return (
                "Do you want Claude to run this command?",
                description,
                boundedPreview(toolInput["command"] as? String)
            )
        case "NotebookEdit":
            return (
                "Do you want Claude to edit \(filename ?? "this notebook")?",
                path,
                boundedPreview(toolInput["new_source"] as? String)
                    ?? prettyPrintedPreview(toolInput)
            )
        case "WebFetch":
            let url = optionalBoundedString(toolInput["url"], maximumBytes: 4_096)
            return (
                "Do you want Claude to fetch this URL?",
                url,
                boundedPreview(toolInput["prompt"] as? String)
            )
        case "WebSearch":
            return (
                "Do you want Claude to search the web?",
                nil,
                boundedPreview(toolInput["query"] as? String)
            )
        default:
            return (
                "Do you want Claude to use \(toolName)?",
                description ?? path,
                prettyPrintedPreview(toolInput)
            )
        }
    }

    /// What "Allow All" would write for this session, or nil when nothing can
    /// be written that grants what the card shows and no more. The card then
    /// has no "Allow All", and Allow Once still grants the one call.
    ///
    /// Claude-authored rules are preferred, with their destination narrowed
    /// to this session, but only rules for the tool on the card: a suggestion
    /// that also covers another tool is not taken. A rule without content
    /// covers every use of its tool, so it is taken only when the card names
    /// no command, file or address of its own (a search, an MCP tool with no
    /// such argument); with one on the card it would allow far more than is
    /// shown. File edits use Claude's documented `acceptEdits` session mode,
    /// the native "allow all edits", and only a file-edit card can ask for
    /// it. Bypass mode is never forwarded.
    private static func sessionPermissionUpdate(
        from value: Any?,
        currentToolName: String,
        toolInput: [String: Any]
    ) -> [String: Any]? {
        let suggestions = value as? [[String: Any]] ?? []
        let editsFiles = isFileMutationTool(currentToolName)
        let cardNamesATarget = namesTarget(toolInput)

        for suggestion in suggestions {
            if suggestion["type"] as? String == "setMode",
               suggestion["mode"] as? String == "acceptEdits" {
                guard editsFiles else { continue }
                return [
                    "type": "setMode",
                    "mode": "acceptEdits",
                    "destination": "session",
                ]
            }

            guard suggestion["type"] as? String == "addRules",
                  suggestion["behavior"] as? String == "allow",
                  let rawRules = suggestion["rules"] as? [[String: Any]],
                  (1...32).contains(rawRules.count) else { continue }

            var rules: [[String: Any]] = []
            for rawRule in rawRules {
                guard let ruleToolName = boundedString(rawRule["toolName"], maximumBytes: 256),
                      ruleToolName == currentToolName || (editsFiles && isFileMutationTool(ruleToolName))
                else {
                    rules.removeAll()
                    break
                }
                var rule: [String: Any] = ["toolName": ruleToolName]
                if let rawContent = rawRule["ruleContent"], !(rawContent is NSNull) {
                    // Content that cannot be carried whole makes the rule
                    // broader than Claude suggested, so the suggestion is
                    // dropped rather than widened.
                    guard let ruleContent = boundedString(rawContent, maximumBytes: 4_096) else {
                        rules.removeAll()
                        break
                    }
                    rule["ruleContent"] = ruleContent
                } else if cardNamesATarget, !editsFiles {
                    // For a file edit, "every edit" is what Allow All means
                    // anyway (see below), so Claude's own rule for it stands.
                    rules.removeAll()
                    break
                }
                rules.append(rule)
            }
            guard rules.count == rawRules.count else { continue }
            return [
                "type": "addRules",
                "rules": rules,
                "behavior": "allow",
                "destination": "session",
            ]
        }

        if editsFiles {
            return [
                "type": "setMode",
                "mode": "acceptEdits",
                "destination": "session",
            ]
        }

        var rule: [String: Any] = ["toolName": currentToolName]
        if currentToolName == "Bash" {
            // Without the command the rule would allow every command.
            guard let command = boundedString(toolInput["command"], maximumBytes: 4_096) else { return nil }
            rule["ruleContent"] = command
        } else if currentToolName == "WebFetch" {
            // Without the domain the rule would allow every site.
            guard let rawURL = boundedString(toolInput["url"], maximumBytes: 4_096),
                  let host = URL(string: rawURL)?.host,
                  !host.isEmpty else { return nil }
            rule["ruleContent"] = "domain:\(host)"
        } else if cardNamesATarget {
            // A file to read, a pattern to search, a command for some other
            // tool: a rule for the whole tool would cover every other one.
            return nil
        }
        return [
            "type": "addRules",
            "rules": [rule],
            "behavior": "allow",
            "destination": "session",
        ]
    }

    /// Whether the tool input points at one particular thing (a command, a
    /// file, an address, a pattern), which a rule for the whole tool would
    /// reach far beyond.
    private static func namesTarget(_ toolInput: [String: Any]) -> Bool {
        ["command", "file_path", "path", "notebook_path", "url", "pattern"].contains { key in
            guard let value = toolInput[key] as? String else { return toolInput[key] != nil && !(toolInput[key] is NSNull) }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// What the update allows, in the owner's words, for the card.
    static func scopeSummary(of update: [String: Any]) -> String {
        if update["type"] as? String == "setMode" { return "every file edit in this session" }
        let rules = update["rules"] as? [[String: Any]] ?? []
        let parts = rules.compactMap { rule -> String? in
            guard let tool = rule["toolName"] as? String else { return nil }
            if let content = rule["ruleContent"] as? String { return "\(tool)(\(content))" }
            return "every use of \(tool)"
        }
        let summary = parts.joined(separator: ", ") + " in this session"
        guard summary.count > 240 else { return summary }
        return String(summary.prefix(239)) + "…"
    }

    private static func isFileMutationTool(_ toolName: String) -> Bool {
        switch toolName {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": true
        default: false
        }
    }

    private static func prettyPrintedPreview(_ value: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return boundedPreview(String(decoding: data, as: UTF8.self))
    }

    private static func boundedPreview(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let maximumBytes = 4_096
        guard trimmed.utf8.count > maximumBytes else { return trimmed }
        let prefix = Data(trimmed.utf8.prefix(maximumBytes - 16))
        return String(decoding: prefix, as: UTF8.self) + "\n… preview clipped"
    }

    private static func boundedString(_ value: Any?, maximumBytes: Int) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes else { return nil }
        return trimmed
    }

    private static func optionalBoundedString(_ value: Any?, maximumBytes: Int) -> String? {
        guard value != nil else { return nil }
        return boundedString(value, maximumBytes: maximumBytes)
    }

}
