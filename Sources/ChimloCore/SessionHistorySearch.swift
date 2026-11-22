import Foundation

/// Filters for the history list. Empty sets and nil bounds mean "any".
public struct HistoryQuery: Equatable, Sendable {
    /// Whitespace-separated tokens; every token must match some field.
    public var text: String
    public var projectPath: String?
    public var statuses: Set<HistoryStatus>
    public var models: Set<String>
    /// Inclusive bounds. A record matches when its active span
    /// (`startedAt`...`lastActivityAt`) overlaps the range, so a long session
    /// that began before `from` still appears.
    public var from: Date?
    public var to: Date?

    public init(
        text: String = "",
        projectPath: String? = nil,
        statuses: Set<HistoryStatus> = [],
        models: Set<String> = [],
        from: Date? = nil,
        to: Date? = nil
    ) {
        self.text = text
        self.projectPath = projectPath
        self.statuses = statuses
        self.models = models
        self.from = from
        self.to = to
    }

    public var isEmpty: Bool {
        HistorySearch.tokens(in: text).isEmpty && projectPath == nil && statuses.isEmpty
            && models.isEmpty && from == nil && to == nil
    }
}

/// Local, in-memory history search.
///
/// Matching is substring-based and case-, diacritic- and width-insensitive,
/// so "cafe" finds "Café" and "CI" finds "ci-fix". Structured filters run
/// first and text fields are prepared only for records that survive them.
///
/// Performance: ASCII fields (paths, branches, most previews) are searched in
/// place with libc's case-insensitive `strcasestr`, so they are never copied
/// or lowercased; only fields with non-ASCII text pay for Foundation folding.
/// Keeping per-byte work in optimized C makes 10k records fast in debug
/// builds too, without an index that would have to be kept in sync.
public enum HistorySearch {
    public static func filter(_ records: [SessionHistoryRecord], query: HistoryQuery) -> [SessionHistoryRecord] {
        let tokens = tokens(in: query.text).map { Array($0.utf8CString) }
        let projectPath = query.projectPath.map(normalizedPath)

        let matches = records.filter { record in
            if !query.statuses.isEmpty, !query.statuses.contains(record.status) { return false }
            if !query.models.isEmpty {
                guard let model = record.model, query.models.contains(model) else { return false }
            }
            if let projectPath {
                guard let recordPath = record.projectPath, normalizedPath(recordPath) == projectPath else { return false }
            }
            if let from = query.from, record.lastActivityAt < from { return false }
            if let to = query.to, record.startedAt > to { return false }
            guard !tokens.isEmpty else { return true }

            let fields = searchableFields(of: record)
            return tokens.allSatisfy { token in fields.contains { $0.contains(token) } }
        }
        return matches.sorted(by: SessionHistoryOrdering.newestFirst)
    }

    /// Folded, non-empty tokens of a free-text query.
    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { fold(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Every searchable field. Tokens contain no whitespace and are matched
    /// per field, so a match never straddles two fields.
    static func searchableFields(of record: SessionHistoryRecord) -> [SearchField] {
        var fields = [SearchField(record.title), SearchField(record.projectName), SearchField(record.status.rawValue)]
        if let path = record.projectPath { fields.append(SearchField(lastPathComponent(of: path))) }
        if let branch = record.gitBranch { fields.append(SearchField(branch)) }
        if let model = record.model { fields.append(SearchField(model)) }
        if let prompt = record.latestUserPrompt { fields.append(SearchField(prompt)) }
        if let response = record.latestAgentResponse { fields.append(SearchField(response)) }
        for agent in record.agents {
            if let type = agent.type { fields.append(SearchField(type)) }
            if let description = agent.description { fields.append(SearchField(description)) }
        }
        for pullRequest in record.pullRequests {
            fields.append(SearchField("\(pullRequest.repository) #\(pullRequest.number)"))
        }
        return fields
    }

    /// One prepared field: the original text when it is pure ASCII, its
    /// folded form otherwise.
    struct SearchField {
        let text: String
        let isASCII: Bool

        init(_ raw: String) {
            isASCII = HistorySearch.isASCII(raw)
            text = isASCII ? raw : HistorySearch.fold(raw)
        }

        /// `token` is a folded, NUL-terminated query token.
        func contains(_ token: [CChar]) -> Bool {
            text.withCString { haystack in
                token.withUnsafeBufferPointer { needle in
                    guard let needle = needle.baseAddress else { return false }
                    // Folded text is already lowercase, so an exact search is
                    // enough; untouched ASCII text relies on strcasestr.
                    return (isASCII ? strcasestr(haystack, needle) : strstr(haystack, needle)) != nil
                }
            }
        }
    }

    /// Bytes 0x01-0x7F, the accept set for `strspn`.
    private static let asciiAcceptSet = String(decoding: (1...127).map { UInt8($0) }, as: UTF8.self)

    /// `strspn` stops at the first byte outside 0x01-0x7F, so covering the
    /// whole string means it is ASCII. Native strings expose their
    /// NUL-terminated storage without copying.
    static func isASCII(_ text: String) -> Bool {
        let span = text.withCString { string in
            asciiAcceptSet.withCString { accept in strspn(string, accept) }
        }
        return span == text.utf8.count
    }

    /// Case-, diacritic- and width-folded lowercase text.
    static func fold(_ text: String) -> String {
        if isASCII(text) { return text.lowercased() }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    /// String-based on purpose: building a `URL` per record is measurable at
    /// 10k records and only the final component is searched.
    static func lastPathComponent(of path: String) -> String {
        let trimmed = normalizedPath(path)
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Drops trailing slashes (keeping a lone "/") so `/repo/` equals `/repo`.
    static func normalizedPath(_ path: String) -> String {
        guard path.utf8.last == UInt8(ascii: "/") else { return path }
        var path = path
        while path.utf8.count > 1, path.utf8.last == UInt8(ascii: "/") { path.removeLast() }
        return path
    }
}
