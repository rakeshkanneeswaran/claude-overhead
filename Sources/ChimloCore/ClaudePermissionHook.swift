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

    public init(data: Data, expiresAt: Date? = nil) throws {
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
            expiresAt: expiresAt
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

    /// Claude-authored rules are preferred, but their destination is narrowed
    /// to this session. File edits fall back to Claude's documented
    /// `acceptEdits` session mode, which is the native "allow all edits"
    /// behavior. Bypass mode is never forwarded by Claude Overhead.
    ///
    /// Returns nil when no rule can be written that matches what the card
    /// shows. A rule without its content covers the whole tool: for Bash that
    /// is every command, so a command (or a suggested rule) too long to carry
    /// must never be shortened to "allow Bash". The card then has no "Allow
    /// All", and Allow Once still grants the one call.
    private static func sessionPermissionUpdate(
        from value: Any?,
        currentToolName: String,
        toolInput: [String: Any]
    ) -> [String: Any]? {
        let suggestions = value as? [[String: Any]] ?? []

        for suggestion in suggestions {
            if suggestion["type"] as? String == "setMode",
               suggestion["mode"] as? String == "acceptEdits" {
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
            var includesCurrentTool = false
            for rawRule in rawRules {
                guard let ruleToolName = boundedString(rawRule["toolName"], maximumBytes: 256)
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
                }
                includesCurrentTool = includesCurrentTool
                    || ruleToolName == currentToolName
                    || (isFileMutationTool(currentToolName) && ruleToolName == "Edit")
                rules.append(rule)
            }
            guard rules.count == rawRules.count, includesCurrentTool else { continue }
            return [
                "type": "addRules",
                "rules": rules,
                "behavior": "allow",
                "destination": "session",
            ]
        }

        if isFileMutationTool(currentToolName) {
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
        }
        return [
            "type": "addRules",
            "rules": [rule],
            "behavior": "allow",
            "destination": "session",
        ]
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
