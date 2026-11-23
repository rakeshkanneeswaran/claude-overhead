import Foundation
import Testing
@testable import ChimloCore

/// A throwaway repository in a temporary directory. Git runs with an isolated
/// environment (no global or system config, a fake HOME, a ceiling directory)
/// so the tests never read or depend on the developer's own git setup.
private struct ScratchRepository {
    let base: String
    let root: String
    let environment: [String: String]

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.base = canonicalPath(base.path)
        root = self.base + "/repo"
        try FileManager.default.createDirectory(atPath: root + "/nested/deeper", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: self.base + "/home", withIntermediateDirectories: true)
        environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": self.base + "/home",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CEILING_DIRECTORIES": self.base,
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        ]
    }

    var reader: GitRepositoryReader {
        GitRepositoryReader(runner: ProcessCommandRunner(environment: environment))
    }

    /// Runs git in the repository; `date` pins both author and committer dates.
    @discardableResult
    func git(_ arguments: [String], date: Date? = nil) async throws -> String {
        var environment = environment
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            environment["GIT_AUTHOR_DATE"] = stamp
            environment["GIT_COMMITTER_DATE"] = stamp
        }
        let result = await ProcessCommandRunner(environment: environment)
            .run("/usr/bin/git", ["-C", root] + arguments, workingDirectory: nil, timeout: Patience.expectedSeconds)
        guard result.succeeded else {
            throw ScratchError.gitFailed(arguments.joined(separator: " "), result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func initialize() async throws {
        try await git(["init", "--quiet", "--initial-branch=main"])
        try await git(["config", "user.name", "Overhead Tests"])
        try await git(["config", "user.email", "tests@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])
    }

    func write(_ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: URL(fileURLWithPath: root + "/" + path))
    }

    func write(_ path: String, bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: root + "/" + path))
    }

    func commit(_ message: String, at date: Date) async throws {
        try await git(["add", "--all"])
        try await git(["commit", "--quiet", "--no-verify", "-m", message], date: date)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: base)
    }
}

private enum ScratchError: Error {
    case gitFailed(String, String)
}

@Suite("Git repository reader")
struct GitRepositoryReaderTests {
    // A session window an hour ago, with commits 20 minutes either side of its
    // start. Checks the `--since` boundary precisely, so a time zone mistake
    // in the date handed to git would show.
    private let sessionStart = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3_600).rounded(.down))

    /// Builds the shared history: an old initial commit, one commit before
    /// the session, one inside it, then uncommitted and untracked work.
    private func makeHistory(_ repo: ScratchRepository) async throws {
        try await repo.initialize()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        try await repo.commit("initial", at: Date(timeIntervalSince1970: 1_577_836_800))

        try await repo.git(["checkout", "--quiet", "-b", "feature/countdown"])
        try repo.write("a.txt", "one\nTWO\nthree\nfour\n")
        try await repo.commit("before the session", at: sessionStart.addingTimeInterval(-1_200))

        try repo.write("a.txt", "one\nTWO\nthree\nfour\nfive\n")
        try repo.write("b.bin", bytes: [0, 1, 2, 0, 255, 0])
        try await repo.commit("inside the session", at: sessionStart.addingTimeInterval(1_200))

        try repo.write("a.txt", "one\nTWO\nthree\nfour\nfive\nsix\n")
        try repo.write("c.txt", "staged one\nstaged two\n")
        try await repo.git(["add", "c.txt"])
        try repo.write("d.txt", "x\ny\nz")
    }

    @Test("Reads root, branch, HEAD, remotes, and the default branch")
    func readsInfo() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }
        try await makeHistory(repo)
        try await repo.git(["remote", "add", "origin", "git@github.com:octo/overhead.git"])
        try await repo.git(["remote", "add", "upstream", "https://github.com/upstream-org/overhead.git"])
        try await repo.git(["remote", "add", "mirror", "/somewhere/local/mirror.git"])
        try await repo.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let head = try await repo.git(["rev-parse", "HEAD"])

        let info = try #require(await repo.reader.info(for: repo.root + "/nested/deeper"))
        #expect(info.root == repo.root)
        #expect(info.branch == "feature/countdown")
        #expect(info.headCommit == head)
        #expect(info.headCommit?.count == 40)
        #expect(info.defaultBranch == "main")
        #expect(info.remotes.count == 2)
        #expect(info.remotes["origin"] == GitRemote(host: "github.com", owner: "octo", name: "overhead"))
        #expect(info.remotes["upstream"]?.fullName == "upstream-org/overhead")
        #expect(info.remotes["mirror"] == nil)
        #expect(info.gitHubRemote?.fullName == "octo/overhead")
    }

    @Test("A detached HEAD has no branch but keeps its commit")
    func detachedHead() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }
        try await makeHistory(repo)
        try await repo.git(["checkout", "--quiet", "--detach"])
        let head = try await repo.git(["rev-parse", "HEAD"])

        let info = try #require(await repo.reader.info(for: repo.root))
        #expect(info.branch == nil)
        #expect(info.headCommit == head)
        #expect(info.defaultBranch == nil)
        #expect(info.remotes.isEmpty)
    }

    @Test("Summarizes commits and file changes since the session started")
    func summarizesChanges() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }
        try await makeHistory(repo)

        let summary = try #require(await repo.reader.changes(in: repo.root, since: sessionStart))
        #expect(summary.commits.map(\.subject) == ["inside the session"])
        #expect(summary.commits.first?.sha.count == 40)
        #expect(summary.commits.first?.date == sessionStart.addingTimeInterval(1_200))
        // a.txt: +1 committed in the window, +1 uncommitted. c.txt is staged.
        #expect(summary.files == [
            GitFileChange(path: "a.txt", added: 2, removed: 0),
            GitFileChange(path: "b.bin", added: nil, removed: nil),
            GitFileChange(path: "c.txt", added: 2, removed: 0),
        ])
        #expect(summary.insertions == 4)
        #expect(summary.deletions == 0)
    }

    @Test("Committed-only summaries leave out the working tree")
    func committedOnly() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }
        try await makeHistory(repo)

        let summary = try #require(await repo.reader.changes(in: repo.root, since: sessionStart, untilNow: false))
        #expect(summary.files == [
            GitFileChange(path: "a.txt", added: 1, removed: 0),
            GitFileChange(path: "b.bin", added: nil, removed: nil),
        ])
        #expect(summary.insertions == 1)
    }

    @Test("Untracked files are counted only when asked for")
    func untrackedFiles() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }
        try await makeHistory(repo)

        let summary = try #require(
            await repo.reader.changes(in: repo.root, since: sessionStart, includeUntracked: true)
        )
        #expect(summary.files.map(\.path) == ["a.txt", "b.bin", "c.txt", "d.txt"])
        #expect(summary.files.last == GitFileChange(path: "d.txt", added: 3, removed: 0))
        #expect(summary.insertions == 7)
    }

    @Test("A window covering the whole history includes every commit, newest first")
    func wholeHistory() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }
        try await makeHistory(repo)

        let summary = try #require(
            await repo.reader.changes(in: repo.root, since: Date(timeIntervalSince1970: 0), untilNow: false)
        )
        #expect(summary.commits.map(\.subject) == ["inside the session", "before the session", "initial"])
        // initial +3, before +2 -1, inside +1: merged per path.
        #expect(summary.files.first == GitFileChange(path: "a.txt", added: 6, removed: 1))
    }

    @Test("A repository with no commits reports its unborn branch and empty changes")
    func unbornRepository() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }
        try await repo.initialize()

        let info = try #require(await repo.reader.info(for: repo.root))
        #expect(info.branch == "main")
        #expect(info.headCommit == nil)

        let summary = try #require(await repo.reader.changes(in: repo.root, since: sessionStart))
        #expect(summary.commits.isEmpty)
        #expect(summary.files.isEmpty)
    }

    @Test("A plain directory or a missing git yields nil")
    func notARepository() async throws {
        let repo = try ScratchRepository()
        defer { repo.remove() }

        #expect(await repo.reader.info(for: repo.root) == nil)
        #expect(await repo.reader.changes(in: repo.root, since: sessionStart) == nil)
        #expect(await repo.reader.info(for: repo.base + "/does-not-exist") == nil)

        try await repo.initialize()
        let missingGit = GitRepositoryReader(
            runner: ProcessCommandRunner(environment: repo.environment),
            gitPath: "/nonexistent/git"
        )
        #expect(await missingGit.info(for: repo.root) == nil)
        #expect(await missingGit.changes(in: repo.root, since: sessionStart) == nil)
    }
}

@Suite("Git output parsing")
struct GitOutputParserTests {
    @Test("Numstat lines parse counts, binary markers, renames, and quoting")
    func numstat() {
        let output = """
        3\t1\tSources/App.swift
        -\t-\tAssets/icon.png

        10\t0\tdocs/{old => new}/guide.md
        2\t2\told.txt => new.txt
        1\t0\tsrc/{ => sub}/file.swift
        0\t5\t"quote\\"d.txt"
        4\t4\tspaced name.txt
        not a numstat line
        x\t1\tbad-count.txt
        """
        #expect(GitOutputParser.numstat(output) == [
            GitFileChange(path: "Sources/App.swift", added: 3, removed: 1),
            GitFileChange(path: "Assets/icon.png", added: nil, removed: nil),
            GitFileChange(path: "docs/new/guide.md", added: 10, removed: 0),
            GitFileChange(path: "new.txt", added: 2, removed: 2),
            GitFileChange(path: "src/sub/file.swift", added: 1, removed: 0),
            GitFileChange(path: "quote\"d.txt", added: 0, removed: 5),
            GitFileChange(path: "spaced name.txt", added: 4, removed: 4),
        ])
    }

    @Test("Merging sums duplicate paths and keeps binaries count-free")
    func merge() {
        let merged = GitOutputParser.merge([
            [GitFileChange(path: "b.swift", added: 1, removed: 2), GitFileChange(path: "img.png", added: nil, removed: nil)],
            [GitFileChange(path: "b.swift", added: 3, removed: 0), GitFileChange(path: "a.swift", added: 5, removed: 5)],
            [GitFileChange(path: "img.png", added: nil, removed: nil)],
        ])
        #expect(merged == [
            GitFileChange(path: "a.swift", added: 5, removed: 5),
            GitFileChange(path: "b.swift", added: 4, removed: 2),
            GitFileChange(path: "img.png", added: nil, removed: nil),
        ])
        let summary = GitChangeSummary(files: merged, commits: [])
        #expect(summary.insertions == 9)
        #expect(summary.deletions == 7)
    }

    @Test("Commit log lines split on the unit separator")
    func commits() {
        let output = "abc123\u{1f}Fix: countdown\u{1f}2026-11-22T10:00:00+05:30\n"
            + "def456\u{1f}\u{1f}2026-11-22T04:00:00Z\n"
            + "malformed line\n"
        let commits = GitOutputParser.commits(output)
        #expect(commits == [
            GitCommit(sha: "abc123", subject: "Fix: countdown", date: Date(timeIntervalSince1970: 1_795_321_800)),
            GitCommit(sha: "def456", subject: "", date: Date(timeIntervalSince1970: 1_795_320_000)),
        ])
    }

    @Test("Remote listings keep fetch URLs only")
    func remotes() {
        let output = """
        origin\tgit@github.com:octo/app.git (fetch)
        origin\tgit@github.com:octo/app-push.git (push)
        partial\thttps://github.com/octo/partial.git (fetch) [blob:none]
        local\t/tmp/mirror.git (fetch)
        """
        let remotes = GitOutputParser.remotes(output)
        #expect(remotes.count == 2)
        #expect(remotes["origin"]?.fullName == "octo/app")
        #expect(remotes["partial"]?.fullName == "octo/partial")
    }

    @Test("Dates handed to git are UTC ISO 8601")
    func gitDate() {
        #expect(GitRepositoryReader.gitDate(Date(timeIntervalSince1970: 1_700_000_000)) == "2023-11-14T22:13:20Z")
    }
}
