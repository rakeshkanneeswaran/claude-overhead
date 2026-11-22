import Foundation

/// A snapshot of where a session's working directory sits in git.
public struct GitRepositoryInfo: Equatable, Sendable, Codable {
    /// The work-tree root as git reports it (symlinks resolved).
    public let root: String
    /// `nil` when HEAD is detached.
    public let branch: String?
    /// `nil` before the first commit.
    public let headCommit: String?
    /// From `refs/remotes/origin/HEAD`; `nil` when the clone never recorded it.
    public let defaultBranch: String?
    /// Remote name to its parsed fetch URL. Remotes whose URL is not a hosted
    /// repository (local paths, `file://`) are left out.
    public let remotes: [String: GitRemote]

    public init(
        root: String,
        branch: String?,
        headCommit: String?,
        defaultBranch: String?,
        remotes: [String: GitRemote]
    ) {
        self.root = root
        self.branch = branch
        self.headCommit = headCommit
        self.defaultBranch = defaultBranch
        self.remotes = remotes
    }

    /// The GitHub repository this checkout most likely belongs to. `origin` is
    /// where pushes and pull requests usually go; `upstream` is the common
    /// name for the parent of a fork. Any other GitHub remote is a stable,
    /// name-ordered fallback.
    public var gitHubRemote: GitRemote? {
        if let origin = remotes["origin"], origin.isGitHub { return origin }
        if let upstream = remotes["upstream"], upstream.isGitHub { return upstream }
        return remotes
            .sorted { $0.key < $1.key }
            .first { $0.value.isGitHub }?
            .value
    }
}

public struct GitFileChange: Equatable, Sendable, Codable {
    public let path: String
    /// `nil` for binary files, where git reports "-" instead of line counts.
    public let added: Int?
    public let removed: Int?

    public init(path: String, added: Int?, removed: Int?) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

public struct GitCommit: Equatable, Sendable, Codable {
    public let sha: String
    public let subject: String
    /// Committer date, so it agrees with the `--since` filter that found it.
    public let date: Date?

    public init(sha: String, subject: String, date: Date?) {
        self.sha = sha
        self.subject = subject
        self.date = date
    }
}

/// What changed in a repository over a period: files with line counts, and
/// the commits made in it.
public struct GitChangeSummary: Equatable, Sendable, Codable {
    public let files: [GitFileChange]
    public let commits: [GitCommit]

    public init(files: [GitFileChange], commits: [GitCommit]) {
        self.files = files
        self.commits = commits
    }

    /// Binary files contribute nothing; they have no line counts.
    public var insertions: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    public var deletions: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
}

/// Reads repository state by running the git executable.
///
/// Every invocation passes `--no-optional-locks`: Overhead polls while Claude
/// Code may be running git in the same repository, and a read-only status
/// check must never take `index.lock` and make the agent's own git fail.
public struct GitRepositoryReader: Sendable {
    /// Recent commits shown for a session; older ones add little at a glance.
    public static let commitLimit = 50
    /// Upper bound on commits scanned for file stats, so a very old `since`
    /// on a large repository stays cheap.
    public static let numstatCommitLimit = 500
    /// Untracked files counted when `includeUntracked` is on.
    public static let untrackedFileLimit = 200
    /// Untracked files larger than this are listed without line counts.
    public static let untrackedByteLimit = 2 * 1024 * 1024

    public let runner: any CommandRunning
    public let gitPath: String
    public let timeout: TimeInterval

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        gitPath: String = "/usr/bin/git",
        timeout: TimeInterval = 10
    ) {
        self.runner = runner
        self.gitPath = gitPath
        self.timeout = timeout
    }

    /// Returns `nil` when `path` is not inside a git work tree or git is
    /// unavailable.
    public func info(for path: String) async -> GitRepositoryInfo? {
        let topLevel = await git(in: path, ["rev-parse", "--show-toplevel"])
        guard topLevel.succeeded, let root = Self.firstLine(topLevel.stdout) else { return nil }

        async let branchResult = git(in: root, ["rev-parse", "--abbrev-ref", "HEAD"])
        async let headResult = git(in: root, ["rev-parse", "--verify", "--quiet", "HEAD"])
        async let remotesResult = git(in: root, ["remote", "-v"])
        async let defaultResult = git(in: root, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])

        let head = await headResult
        let headCommit = head.succeeded ? Self.firstLine(head.stdout) : nil

        let branchOutput = await branchResult
        var branch: String?
        if branchOutput.succeeded {
            // `--abbrev-ref` prints the literal "HEAD" when detached.
            branch = Self.firstLine(branchOutput.stdout).flatMap { $0 == "HEAD" ? nil : $0 }
        } else if headCommit == nil {
            // Before the first commit HEAD cannot be resolved, but it still
            // names the unborn branch.
            let unborn = await git(in: root, ["symbolic-ref", "--quiet", "--short", "HEAD"])
            branch = unborn.succeeded ? Self.firstLine(unborn.stdout) : nil
        }

        let remotesOutput = await remotesResult
        let remotes = remotesOutput.succeeded ? GitOutputParser.remotes(remotesOutput.stdout) : [:]

        let defaultOutput = await defaultResult
        let defaultBranch = defaultOutput.succeeded
            ? Self.firstLine(defaultOutput.stdout).map { ref in
                ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
            }
            : nil

        return GitRepositoryInfo(
            root: root,
            branch: branch,
            headCommit: headCommit,
            defaultBranch: defaultBranch,
            remotes: remotes
        )
    }

    /// Summarizes work since `since`: commits on HEAD (newest first, capped at
    /// `commitLimit`) and per-file line counts across those commits.
    ///
    /// - Parameters:
    ///   - untilNow: also count uncommitted work (staged and unstaged changes
    ///     against HEAD), so a session that has not committed yet still shows
    ///     its edits.
    ///   - includeUntracked: with `untilNow`, also list new files git does not
    ///     track yet, counting their lines. Off by default because it reads
    ///     file contents rather than asking git.
    /// - Returns: `nil` when `root` is not a git work tree or git is unavailable.
    public func changes(
        in root: String,
        since: Date,
        untilNow: Bool = true,
        includeUntracked: Bool = false
    ) async -> GitChangeSummary? {
        let sinceArgument = "--since=\(Self.gitDate(since))"
        let logOptions = ["--no-color", "--no-show-signature", "--no-ext-diff", "--no-textconv"]

        async let commitsResult = git(
            in: root,
            ["log", sinceArgument, "--max-count=\(Self.commitLimit)"] + logOptions
                + ["--format=%H%x1f%s%x1f%cI"]
        )
        async let committedResult = git(
            in: root,
            ["log", sinceArgument, "--max-count=\(Self.numstatCommitLimit)"] + logOptions
                + ["--numstat", "--format="]
        )
        async let workingResult: CommandResult? = untilNow
            ? git(in: root, ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--numstat", "HEAD"])
            : nil
        async let untrackedResult: [GitFileChange] = untilNow && includeUntracked
            ? untrackedChanges(in: root)
            : []

        let commitsOutput = await commitsResult
        guard commitsOutput.succeeded else {
            // `git log` also fails before the first commit; that is an empty
            // history, not a missing repository.
            let inside = await git(in: root, ["rev-parse", "--is-inside-work-tree"])
            guard inside.succeeded, Self.firstLine(inside.stdout) == "true" else { return nil }
            return GitChangeSummary(files: GitOutputParser.merge([await untrackedResult]), commits: [])
        }

        let committedOutput = await committedResult
        let committed = committedOutput.succeeded ? GitOutputParser.numstat(committedOutput.stdout) : []
        let working: [GitFileChange]
        if let workingOutput = await workingResult, workingOutput.succeeded {
            working = GitOutputParser.numstat(workingOutput.stdout)
        } else {
            working = []
        }

        return GitChangeSummary(
            files: GitOutputParser.merge([committed, working, await untrackedResult]),
            commits: GitOutputParser.commits(commitsOutput.stdout)
        )
    }

    private func untrackedChanges(in root: String) async -> [GitFileChange] {
        let output = await git(in: root, ["ls-files", "--others", "--exclude-standard", "-z"])
        guard output.succeeded else { return [] }
        return output.stdout
            .split(separator: "\0")
            .prefix(Self.untrackedFileLimit)
            .map { path in
                let path = String(path)
                let lines = Self.lineCount(ofFileAt: URL(fileURLWithPath: root).appendingPathComponent(path).path)
                return GitFileChange(path: path, added: lines, removed: lines == nil ? nil : 0)
            }
    }

    /// Lines in a regular text file, or `nil` for binaries, symlinks, and files
    /// too large to read cheaply. A NUL byte marks binary, as git's own
    /// heuristic does.
    static func lineCount(ofFileAt path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int,
              size <= untrackedByteLimit,
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        guard !data.prefix(8000).contains(0) else { return nil }
        guard let last = data.last else { return 0 }
        let newlines = data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        return last == UInt8(ascii: "\n") ? newlines : newlines + 1
    }

    private func git(in directory: String, _ arguments: [String]) async -> CommandResult {
        // `core.quotepath=off` keeps non-ASCII paths readable instead of
        // octal-escaped.
        await runner.run(
            gitPath,
            ["--no-optional-locks", "-c", "core.quotepath=off", "-C", directory] + arguments,
            workingDirectory: nil,
            timeout: timeout
        )
    }

    /// Strict ISO 8601 in UTC ("2026-11-22T10:00:00Z"), which git's date
    /// parser reads unambiguously regardless of the local time zone.
    static func gitDate(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Not whitespace-trimmed: a work-tree path may legally end in a space.
    private static func firstLine(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first, !line.isEmpty else { return nil }
        return String(line)
    }
}

/// Parsers for git's plumbing output, kept separate from process handling so
/// they can be tested with literal strings.
enum GitOutputParser {
    /// Parses `--numstat` lines: `added<TAB>removed<TAB>path`, with "-" counts
    /// for binary files. Blank separator lines and anything unrecognized are
    /// skipped.
    static func numstat(_ output: String) -> [GitFileChange] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let added = Int(fields[0])
            let removed = Int(fields[1])
            guard added != nil || fields[0] == "-", removed != nil || fields[1] == "-" else { return nil }
            let path = renamedPath(unquote(String(fields[2])))
            guard !path.isEmpty else { return nil }
            return GitFileChange(path: path, added: added, removed: removed)
        }
    }

    /// Resolves numstat rename notation to the new path:
    /// `old => new` and `dir/{old => new}/file`.
    static func renamedPath(_ path: String) -> String {
        guard path.contains(" => ") else { return path }
        if let open = path.firstIndex(of: "{"),
           let close = path[open...].firstIndex(of: "}"),
           let arrow = path.range(of: " => ", range: open..<close) {
            let prefix = path[..<open]
            let newPart = path[arrow.upperBound..<close]
            let suffix = path[path.index(after: close)...]
            var joined = prefix + newPart + suffix
            while let doubled = joined.range(of: "//") {
                joined.replaceSubrange(doubled, with: "/")
            }
            return String(joined)
        }
        guard let arrow = path.range(of: " => ") else { return path }
        return String(path[arrow.upperBound...])
    }

    /// Git quotes paths containing quotes, backslashes, or control characters
    /// even with `core.quotepath=off`.
    static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var result = ""
        var escaping = false
        for character in path.dropFirst().dropLast() {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Parses `--format=%H%x1f%s%x1f%cI` lines. The unit separator cannot
    /// appear in a commit subject, so splitting on it is unambiguous.
    static func commits(_ output: String) -> [GitCommit] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 3, let sha = fields.first, let dateField = fields.last, !sha.isEmpty else {
                return nil
            }
            let subject = fields.dropFirst().dropLast().joined(separator: "\u{1f}")
            return GitCommit(
                sha: String(sha),
                subject: subject,
                date: try? Date(String(dateField), strategy: .iso8601)
            )
        }
    }

    /// Parses `git remote -v`, keeping fetch URLs. Lines look like
    /// `origin<TAB>git@github.com:o/r.git (fetch)`, sometimes followed by a
    /// partial-clone filter.
    static func remotes(_ output: String) -> [String: GitRemote] {
        var remotes: [String: GitRemote] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, let marker = fields[1].range(of: " (fetch)") else { continue }
            let url = String(fields[1][..<marker.lowerBound])
            if let remote = GitRemote.parse(url) {
                remotes[String(fields[0])] = remote
            }
        }
        return remotes
    }

    /// Combines change lists, summing counts for paths that appear more than
    /// once. A binary entry anywhere makes the merged counts `nil`.
    static func merge(_ lists: [[GitFileChange]]) -> [GitFileChange] {
        var merged: [String: GitFileChange] = [:]
        for change in lists.joined() {
            guard let existing = merged[change.path] else {
                merged[change.path] = change
                continue
            }
            merged[change.path] = GitFileChange(
                path: change.path,
                added: sum(existing.added, change.added),
                removed: sum(existing.removed, change.removed)
            )
        }
        return merged.values.sorted { $0.path < $1.path }
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }
}
