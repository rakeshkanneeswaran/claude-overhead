import Foundation

public enum ProviderHookSource: String, Codable, Sendable {
    case claude

    public var agent: AgentKind {
        switch self {
        case .claude: .claude
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        }
    }
}

public enum ProviderHookMappingError: Error, LocalizedError, Sendable {
    case payloadTooLarge
    case malformedPayload
    case missingSessionID

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge: "Hook payload exceeds the local safety limit"
        case .malformedPayload: "Hook payload is not valid JSON"
        case .missingSessionID: "Hook payload has no session identifier"
        }
    }
}

/// Converts provider hook JSON into the deliberately small status vocabulary
/// Claude Overhead needs. Unknown JSON fields are never decoded, which prevents prompts,
/// transcripts, tool inputs, outputs, and file contents from entering app state.
public enum PrivacySafeHookMapper {
    public static let maximumPayloadBytes = 64 * 1024

    public static func event(
        from data: Data,
        source: ProviderHookSource,
        timestamp: Date = Date()
    ) throws -> AgentEvent? {
        guard data.count <= maximumPayloadBytes else {
            throw ProviderHookMappingError.payloadTooLarge
        }

        let input: HookInput
        do {
            input = try JSONDecoder().decode(HookInput.self, from: data)
        } catch {
            throw ProviderHookMappingError.malformedPayload
        }

        let sessionID = input.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, sessionID.utf8.count <= 512 else {
            throw ProviderHookMappingError.missingSessionID
        }

        let projectPath = bounded(input.cwd, maximumUTF8Bytes: 4_096)
        let title = projectTitle(from: projectPath) ?? "\(source.displayName) session"
        let hookName = input.hookEventName
        let notification = input.notificationType
        let toolName = safeToolName(input.toolName)

        let mapping = map(hookName: hookName, notification: notification, toolName: toolName, source: source)
        guard let mapping else { return nil }

        return AgentEvent(
            sessionID: sessionID,
            sequence: 0,
            kind: mapping.kind,
            agent: source.agent,
            title: title,
            detail: mapping.detail,
            model: bounded(input.model, maximumUTF8Bytes: 128),
            projectPath: projectPath,
            request: mapping.request,
            timestamp: timestamp
        )
    }

    private static func map(
        hookName: String,
        notification: String?,
        toolName: String?,
        source: ProviderHookSource
    ) -> Mapping? {
        switch hookName {
        case "SessionStart":
            return Mapping(kind: .sessionStarted, detail: "Connected locally")
        case "UserPromptSubmit", "PostToolUse", "SubagentStart":
            // Between tools Claude is reasoning about what to do next.
            return Mapping(kind: .activity, detail: "Thinking")
        case "PreToolUse":
            // AskUserQuestion has a separate blocking bridge. The asynchronous
            // observer must not race it and clear the pending question state.
            guard toolName != "AskUserQuestion" else { return nil }
            // The tool name says what Claude is doing right now: reading,
            // writing, running a command. Only its category is kept.
            let activity = toolName.map(ToolActivityKind.init(toolName:)) ?? .other
            return Mapping(kind: .activity, detail: activity.label)
        case "PermissionRequest":
            // Claude permissions have a separate blocking bridge. An
            // asynchronous observer would race the explicit response and
            // could restore a permission card after it was resolved.
            return nil
        case "PermissionDenied":
            return Mapping(kind: .activity, detail: "Approval handled in \(source.displayName)")
        case "Stop", "SubagentStop", "TaskCompleted":
            return Mapping(kind: .completed, detail: "Turn complete")
        case "StopFailure":
            return Mapping(kind: .failed, detail: "Turn stopped")
        case "SessionEnd":
            return Mapping(kind: .sessionEnded, detail: "Session ended")
        case "Notification":
            switch notification {
            case "permission_prompt":
                // Same reason as PermissionRequest: the blocking bridge owns it.
                return nil
            case "agent_needs_input", "idle_prompt":
                // Not a question. idle_prompt means Claude finished a while
                // ago and is waiting for the next prompt; agent_needs_input
                // also covers auto mode's billing notice. Real questions
                // arrive through the AskUserQuestion bridge.
                return nil
            case "agent_completed":
                return Mapping(kind: .completed, detail: "Turn complete")
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func safeToolName(_ value: String?) -> String? {
        guard let value = bounded(value, maximumUTF8Bytes: 80) else { return nil }
        let allowed = value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- ")).contains($0)
        }
        return allowed ? value : nil
    }

    private static func bounded(_ value: String?, maximumUTF8Bytes: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return nil }
        return value
    }

    private static func projectTitle(from path: String?) -> String? {
        guard let path else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private struct Mapping {
        let kind: AgentEventKind
        let detail: String
        var request: PendingRequest?
    }

    private struct HookInput: Decodable {
        let sessionID: String
        let hookEventName: String
        let cwd: String?
        let model: String?
        let notificationType: String?
        let toolName: String?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case hookEventName = "hook_event_name"
            case cwd
            case model
            case notificationType = "notification_type"
            case toolName = "tool_name"
        }
    }
}
