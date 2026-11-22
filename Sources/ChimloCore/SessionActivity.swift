import Foundation

/// Where one tool call stands, as the transcript says it. `unknown` is a call
/// whose result never arrived: the turn ended, the owner interrupted, or the
/// session went quiet. It is never shown as still running.
public enum ActivityStatus: String, Codable, Sendable, CaseIterable {
    case running
    case completed
    case failed
    case unknown

    public var label: String {
        switch self {
        case .running: "Running"
        case .completed: "Done"
        case .failed: "Failed"
        case .unknown: "No result"
        }
    }
}

/// One main-chain tool call from a Claude Code transcript, in Claude's own
/// words. Nothing here is generated: `summary` is the description Claude
/// wrote for the call, verbatim, and `target` is what the call acts on (the
/// command, the file, the pattern), redacted. Tool output is never kept.
public struct SessionActivity: Codable, Equatable, Sendable, Identifiable {
    /// The `tool_use` id, which the matching `tool_result` echoes back.
    public let id: String
    /// The tool's name as Claude Code records it, for example `Bash`.
    public let tool: String
    public let kind: ToolActivityKind
    /// Claude's own description of the call (Bash and Agent descriptions),
    /// on one line, capped at 200 characters.
    public let summary: String?
    /// The redacted command, the file path (relative to the project when it
    /// is inside it), the search pattern, the URL without its query, or the
    /// search query. Capped at 200 characters.
    public let target: String?
    public let startedAt: Date?
    public var finishedAt: Date?
    public var status: ActivityStatus
    /// A Bash call that runs a test suite.
    public let isTestRun: Bool

    public init(
        id: String,
        tool: String,
        kind: ToolActivityKind? = nil,
        summary: String? = nil,
        target: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        status: ActivityStatus = .running,
        isTestRun: Bool = false
    ) {
        self.id = id
        self.tool = tool
        self.kind = kind ?? ToolActivityKind(toolName: tool)
        self.summary = summary
        self.target = target
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.isTestRun = isTestRun
    }

    /// The tool's name for display. MCP tools read as `tool (server)`, since
    /// `mcp__server__tool` is an implementation detail.
    public var toolDisplayName: String { Self.displayName(forTool: tool) }

    /// What the call is about, most specific first: Claude's description,
    /// then the target, then the tool itself.
    public var headline: String { summary ?? target ?? toolDisplayName }

    /// Whether `target` is a path, whose end matters more than its start.
    public var targetIsPath: Bool {
        switch tool {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead": true
        default: false
        }
    }

    /// The status to show while the session is (or is not) believed to be
    /// working. A call cannot still be running in a session that has stopped,
    /// so a missing result then reads as unknown rather than as live work.
    public func presentedStatus(sessionIsWorking: Bool) -> ActivityStatus {
        status == .running && !sessionIsWorking ? .unknown : status
    }

    static func displayName(forTool tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2, let name = parts.last, !name.isEmpty else { return tool }
        let server = parts.dropLast().joined(separator: "__")
            .replacingOccurrences(of: "claude_ai_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return server.isEmpty ? name : "\(name) (\(server))"
    }
}

// MARK: - Display text

/// Turns raw tool inputs into display text that is safe to put on screen:
/// one line, bounded, and with credentials removed. It only removes text;
/// it never rewrites or invents any.
public enum ActivityText {
    public static let maximumCharacters = 200
    /// Heredocs can make a command arbitrarily large; only the start is read.
    private static let maximumAnalyzedUTF8Bytes = 16_384
    static let redaction = "•••"

    /// The first line of a Bash command, without a leading `cd <dir> &&`,
    /// with credentials and assignment values redacted.
    public static func command(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let analyzed = String(decoding: raw.utf8.prefix(maximumAnalyzedUTF8Bytes), as: UTF8.self)
        guard var line = analyzed
            .split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        line = replacing(directoryChange, in: line, with: "")
        line = redactingSecrets(in: line)
        return bounded(line, keepingEnd: false)
    }

    /// Free text Claude wrote (a description, a pattern, a query): one line,
    /// credentials redacted, capped.
    public static func singleLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let analyzed = String(decoding: raw.utf8.prefix(maximumAnalyzedUTF8Bytes), as: UTF8.self)
        let normalized = analyzed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return bounded(redactingSecrets(in: normalized), keepingEnd: false)
    }

    /// A path relative to the project when it lies inside it, otherwise
    /// with the home folder shortened to `~`. Long paths keep their end.
    public static func path(_ raw: String?, workingDirectory: String?, home: String?) -> String? {
        guard let raw else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains(where: \.isNewline) else { return nil }
        var display = path
        if let workingDirectory = normalizedDirectory(workingDirectory), path.hasPrefix(workingDirectory) {
            display = String(path.dropFirst(workingDirectory.count))
        } else if let home = normalizedDirectory(home), path.hasPrefix(home) {
            display = "~/" + String(path.dropFirst(home.count))
        }
        return bounded(display, keepingEnd: true)
    }

    /// The URL's host and path. The query, the fragment and any credentials
    /// are dropped: that is where tokens live.
    public static func url(_ raw: String?) -> String? {
        guard let raw, let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let host = components.host, !host.isEmpty else { return nil }
        let path = components.percentEncodedPath
        return bounded(redactingSecrets(in: host + (path == "/" ? "" : path)), keepingEnd: false)
    }

    // MARK: Redaction

    /// Every pattern Claude Overhead redacts, applied in order. Values go;
    /// the key or flag stays so the line still reads.
    public static func redactingSecrets(in text: String) -> String {
        rules.reduce(redactingAssignments(in: text)) { text, rule in
            replacing(rule.pattern, in: text, with: rule.template)
        }
    }

    /// `NAME=value` words are where tokens are passed inline, so their values
    /// go, unless the value is plainly not a credential: a path or a shell
    /// reference (`S=/tmp/x`, `L=$S/live`). A secret-sounding name always
    /// loses its value.
    static func redactingAssignments(in text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in assignment.matches(in: text, range: range).reversed() {
            guard let nameRange = Range(match.range(at: 2), in: text),
                  let valueRange = Range(match.range(at: 3), in: text),
                  let resultRange = Range(match.range(at: 3), in: result) else { continue }
            let name = String(text[nameRange])
            let value = text[valueRange]
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let looksHarmless = ["/", "~/", "./", "../", "$"].contains { unquoted.hasPrefix($0) }
                && !unquoted.contains(where: \.isWhitespace)
            let secretName = secretSoundingName.firstMatch(
                in: name,
                range: NSRange(name.startIndex..., in: name)
            ) != nil
            guard secretName || !looksHarmless else { continue }
            result.replaceSubrange(resultRange, with: redaction)
        }
        return result
    }

    private static let assignment: NSRegularExpression = (try? NSRegularExpression(
        pattern: #"(^|\s)([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s;&|]+)"#
    )) ?? .neverMatching

    private static let secretSoundingName: NSRegularExpression = (try? NSRegularExpression(
        pattern: "token|secret|passw|pwd|key|auth|cred|cookie|session|private|signature|salt|cert",
        options: [.caseInsensitive]
    )) ?? .neverMatching

    private struct Rule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let template: String
    }

    private static func rule(_ pattern: String, _ template: String, caseInsensitive: Bool = false) -> Rule {
        // The patterns are literals, so a failure is a programming error that
        // the test suite catches; never crash a running notch over it.
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        let expression = (try? NSRegularExpression(pattern: pattern, options: options))
            ?? NSRegularExpression.neverMatching
        return Rule(pattern: expression, template: template)
    }

    private static let rules: [Rule] = [
        // user:password@ in URLs.
        rule(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/@:]+:[^\s/@]+@"#, "$1•••@"),
        // Authorization-style headers.
        rule(#"((?:authorization|proxy-authorization|x-api-key|api-key|private-token|cookie)\s*:\s*)[^"'\n]+"#, "$1•••", caseInsensitive: true),
        // Prose says "basic validation"; a credential is long and has digits.
        rule(#"\b(bearer|basic)\s+(?=[A-Za-z0-9._~+/=\-]*[0-9])[A-Za-z0-9._~+/=\-]{16,}"#, "$1 •••", caseInsensitive: true),
        // Flags that take a secret: --token X, --password=X, -p=X is too
        // ambiguous, so only spelled-out names.
        rule(#"(--?(?:password|passwd|pass|token|secret|api-?key|access-?token|auth-?token|client-?secret|private-?key)(?:=|\s+))("[^"]*"|'[^']*'|\S+)"#, "$1•••", caseInsensitive: true),
        // Well-known token shapes.
        rule(#"\bgh[pousr]_[A-Za-z0-9]{16,}"#, "•••"),
        rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "•••"),
        rule(#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}"#, "•••"),
        rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, "•••"),
        rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, "•••"),
        rule(#"\bAIza[0-9A-Za-z_\-]{35}\b"#, "•••"),
        rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, "•••"),
        // Any other long run that mixes cases and digits reads as a key.
        // Hex digests (one case) and paths (split by / and -) survive.
        rule(#"(?<![A-Za-z0-9+=])(?=[A-Za-z0-9+=]*[A-Z])(?=[A-Za-z0-9+=]*[a-z])(?=[A-Za-z0-9+=]*[0-9])[A-Za-z0-9+=]{32,}"#, "•••"),
    ]

    private static let directoryChange: NSRegularExpression = (try? NSRegularExpression(
        pattern: #"^cd\s+("[^"]*"|'[^']*'|[^\s;&|]+)\s*(?:&&|;)\s*"#
    )) ?? .neverMatching

    private static func replacing(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty, directory != "/" else { return nil }
        return directory.hasSuffix("/") ? directory : directory + "/"
    }

    private static func bounded(_ text: String, keepingEnd: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumCharacters else { return trimmed }
        return keepingEnd
            ? "…" + String(trimmed.suffix(maximumCharacters - 1))
            : String(trimmed.prefix(maximumCharacters - 1)) + "…"
    }
}

private extension NSRegularExpression {
    /// A stand-in that matches nothing, should a literal pattern ever fail.
    static let neverMatching: NSRegularExpression = {
        // `(?!)` always fails to match and always compiles.
        try! NSRegularExpression(pattern: "(?!)")
    }()
}

// MARK: - Sessions

/// A session's standing for ordering and display. Raw values order the list:
/// whatever needs the owner first, older sessions last.
public enum SessionRunState: Int, Codable, Sendable, Comparable, CaseIterable {
    /// A permission or a question is waiting on the owner.
    case needsYou = 0
    /// Stopped with an error, recently.
    case failed
    /// Working now, by evidence that is still fresh.
    case running
    /// The turn is over and Claude Code is open, waiting for the next prompt.
    case waitingInput
    /// Finished recently.
    case recentlyCompleted
    /// Anything older, including work that went quiet.
    case older

    public static func < (lhs: SessionRunState, rhs: SessionRunState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .running: "Running"
        case .waitingInput: "Waiting for you"
        case .recentlyCompleted: "Done"
        case .older: "Idle"
        }
    }

    /// Work with no new evidence for this long is no longer called running,
    /// unless Claude Code itself still reports the session busy. Long enough
    /// for a slow test suite, which writes nothing until it returns.
    public static let staleWorkingAfter: TimeInterval = 20 * 60
    /// How long a finished or failed session counts as recent.
    public static let recentAfter: TimeInterval = 30 * 60
    /// Claude Code's listing can lag a turn; an idle report only overrides
    /// fresher working evidence after this long.
    public static let idleListingGrace: TimeInterval = 60

    /// - Parameters:
    ///   - phase: the session's phase from hooks and the transcript.
    ///   - hasOwnerInteraction: a permission or question is on screen.
    ///   - updatedAt: the newest evidence about the session.
    ///   - liveStatus: Claude Code's own `busy`/`idle`, or `nil` when it does
    ///     not list the session (or the listing is unavailable).
    public static func classify(
        phase: SessionPhase,
        hasOwnerInteraction: Bool,
        updatedAt: Date,
        liveStatus: String?,
        now: Date = .now
    ) -> SessionRunState {
        if hasOwnerInteraction { return .needsYou }
        let age = now.timeIntervalSince(updatedAt)
        let live = liveStatus?.lowercased()
        switch phase {
        case .waitingForApproval, .waitingForAnswer:
            return .needsYou
        case .failed:
            return age <= recentAfter ? .failed : .older
        case .working:
            if live == "busy" { return .running }
            if live != nil, age > idleListingGrace { return .waitingInput }
            if age <= staleWorkingAfter { return .running }
            return .older
        case .completed:
            if live == "busy" { return .running }
            if live != nil { return .waitingInput }
            return age <= recentAfter ? .recentlyCompleted : .older
        }
    }
}

/// The expanded notch's order: needs-you, failed, running, waiting for
/// input, recently finished, older; newest first inside each group, and the
/// session id as a final tiebreak so the order never flickers.
public enum SessionOrdering {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let state: SessionRunState
        public let updatedAt: Date

        public init(id: String, state: SessionRunState, updatedAt: Date) {
            self.id = id
            self.state = state
            self.updatedAt = updatedAt
        }
    }

    public static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state < rhs.state }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }
}

/// Which session the closed notch speaks for: the one that needs the owner,
/// else the selected one while it runs, else the most recent running one.
/// `nil` when nothing runs, and the notch falls back to its plain status.
public enum NotchActivityFocus {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let state: SessionRunState
        public let updatedAt: Date

        public init(id: String, state: SessionRunState, updatedAt: Date) {
            self.id = id
            self.state = state
            self.updatedAt = updatedAt
        }
    }

    public static func sessionID(among candidates: [Candidate], selected: String?) -> String? {
        if let needsYou = newest(candidates.filter { $0.state == .needsYou }) { return needsYou.id }
        let running = candidates.filter { $0.state == .running }
        if let selected, running.contains(where: { $0.id == selected }) { return selected }
        return newest(running)?.id
    }

    private static func newest(_ candidates: [Candidate]) -> Candidate? {
        candidates.min { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }
}

/// The closed notch's one line of activity, with the most important thing
/// first. Built from data only; when nothing specific is known it falls back
/// to the session's plain status.
public struct CompactActivityLine: Equatable, Sendable {
    public enum Tone: String, Equatable, Sendable {
        case attention, working, failed, quiet
    }

    public let tool: String?
    public let text: String
    public let tone: Tone
    public let kind: ToolActivityKind?
    /// The text is a path, so truncate in the middle and keep the file name.
    public let truncatesMiddle: Bool

    public init(tool: String?, text: String, tone: Tone, kind: ToolActivityKind?, truncatesMiddle: Bool = false) {
        self.tool = tool
        self.text = text
        self.tone = tone
        self.kind = kind
        self.truncatesMiddle = truncatesMiddle
    }

    /// - Parameters:
    ///   - permissionTool: the tool a pending permission is for.
    ///   - hasQuestion: Claude is asking the owner something.
    ///   - latest: the session's newest activity, if any.
    ///   - fallback: the plain status, for example "Running a command".
    public static func make(
        permissionTool: String?,
        hasQuestion: Bool,
        latest: SessionActivity?,
        isWorking: Bool,
        fallback: String
    ) -> CompactActivityLine {
        if let permissionTool {
            return CompactActivityLine(
                tool: SessionActivity.displayName(forTool: permissionTool),
                text: "Needs your permission",
                tone: .attention,
                kind: ToolActivityKind(toolName: permissionTool)
            )
        }
        if hasQuestion {
            return CompactActivityLine(tool: nil, text: "Claude has a question for you", tone: .attention, kind: .asking)
        }
        guard isWorking, let latest else {
            return CompactActivityLine(tool: nil, text: fallback, tone: isWorking ? .working : .quiet, kind: nil)
        }
        let status = latest.presentedStatus(sessionIsWorking: isWorking)
        return CompactActivityLine(
            tool: latest.toolDisplayName,
            text: latest.headline,
            tone: status == .failed ? .failed : .working,
            kind: latest.kind,
            truncatesMiddle: latest.summary == nil && latest.targetIsPath
        )
    }
}
