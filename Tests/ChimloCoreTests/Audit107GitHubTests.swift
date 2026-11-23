import Foundation
import Testing
@testable import ChimloCore

/// Answers by URL path; each path holds a queue of replies and the last one
/// repeats. A reply with an ETag answers 304 to a request that sends it back.
/// Unknown paths get 404.
private final class AuditTransport: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var etag: String?
    }

    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var recorded: [URLRequest] = []
    private var notModified = 0

    func on(_ path: String, status: Int = 200, body: String, etag: String? = nil) {
        lock.withLock { routes[path, default: []].append(Reply(status: status, body: body, etag: etag)) }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var notModifiedCount: Int { lock.withLock { notModified } }

    var transport: GitHubTransport {
        { [self] request in try self.respond(to: request) }
    }

    private func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let reply = lock.withLock { () -> Reply in
            recorded.append(request)
            let path = request.url?.path ?? ""
            guard var queue = routes[path], let first = queue.first else {
                return Reply(status: 404, body: #"{"message":"Not Found"}"#, etag: nil)
            }
            if queue.count > 1 {
                queue.removeFirst()
                routes[path] = queue
            }
            if let etag = first.etag, request.value(forHTTPHeaderField: "If-None-Match") == etag {
                notModified += 1
                return Reply(status: 304, body: "", etag: etag)
            }
            return first
        }
        var headers: [String: String] = [:]
        if let etag = reply.etag { headers["ETag"] = etag }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { throw URLError(.badServerResponse) }
        return (Data(reply.body.utf8), response)
    }
}

private enum AuditFixtures {
    static let repo = GitRemote(host: "github.com", owner: "octo", name: "app")

    /// A pull request as the list endpoint returns it.
    static func pull(_ number: Int, sha: String, updated: String = "2026-11-20T10:00:00Z") -> String {
        """
        {"number": \(number), "state": "open", "title": "PR \(number)",
         "html_url": "https://github.com/octo/app/pull/\(number)",
         "user": {"login": "alice"}, "updated_at": "\(updated)", "merged_at": null, "draft": false,
         "requested_reviewers": [], "requested_teams": [],
         "head": {"ref": "branch-\(number)", "sha": "\(sha)", "repo": {"full_name": "octo/app"}},
         "base": {"ref": "main", "sha": "base000", "repo": {"full_name": "octo/app"}}}
        """
    }

    static func list(_ pulls: [String]) -> String { "[\(pulls.joined(separator: ","))]" }

    static let checksFailed = #"{"total_count": 1, "check_runs": [{"id": 1, "name": "test", "status": "completed", "conclusion": "failure"}]}"#
    static let checksPassed = #"{"total_count": 1, "check_runs": [{"id": 1, "name": "test", "status": "completed", "conclusion": "success"}]}"#
    static let approved = #"[{"user": {"login": "bob"}, "state": "APPROVED", "submitted_at": "2026-11-19T09:00:00Z"}]"#

    static func pullRequest(
        _ number: Int,
        sha: String? = "sha1",
        review: GitHubReviewState = .none,
        ci: CIState = .unknown,
        mergeable: String? = nil,
        author: String = "alice"
    ) -> GitHubPullRequest {
        GitHubPullRequest(
            repository: "octo/app", number: number, title: "PR \(number)",
            url: "https://github.com/octo/app/pull/\(number)", author: author,
            headRef: "branch-\(number)", headRepository: "octo/app", headSha: sha, baseRef: "main",
            isDraft: false, state: "open", merged: false, updatedAt: nil,
            mergeableState: mergeable, reviewState: review, ciState: ci
        )
    }
}

@Suite("Audit 1.0.7: pull request detail carried between refreshes")
struct Audit107GitHubDetailCarryTests {
    private func client(_ fake: AuditTransport) -> GitHubClient {
        GitHubClient(credential: GitHubCredential(token: "test-token", source: .personalAccessToken), transport: fake.transport)
    }

    @Test("A pull request past the detail limit keeps its review and CI state, so nothing is announced twice")
    func pastTheDetailLimit() async throws {
        let fake = AuditTransport()
        // First pass: #1 is newest and the only one looked up. Second pass:
        // #2 was touched, so #1 drops out of the detail window.
        fake.on("/repos/octo/app/pulls", body: AuditFixtures.list([AuditFixtures.pull(1, sha: "aaa"), AuditFixtures.pull(2, sha: "bbb")]))
        fake.on("/repos/octo/app/pulls", body: AuditFixtures.list([AuditFixtures.pull(2, sha: "bbb"), AuditFixtures.pull(1, sha: "aaa")]))
        fake.on("/repos/octo/app/pulls", body: AuditFixtures.list([AuditFixtures.pull(1, sha: "aaa"), AuditFixtures.pull(2, sha: "bbb")]))
        fake.on("/repos/octo/app/pulls/1/reviews", body: AuditFixtures.approved)
        fake.on("/repos/octo/app/commits/aaa/check-runs", body: AuditFixtures.checksFailed)
        fake.on("/repos/octo/app/pulls/2/reviews", body: "[]")
        fake.on("/repos/octo/app/commits/bbb/check-runs", body: AuditFixtures.checksPassed)
        let client = client(fake)

        let first = try await client.openPullRequests(AuditFixtures.repo, detailLimit: 1)
        #expect(first.first { $0.number == 1 }?.ciState == .failure)
        #expect(first.first { $0.number == 1 }?.reviewState == .approved)

        let second = try await client.openPullRequests(AuditFixtures.repo, detailLimit: 1, previous: first)
        let carried = try #require(second.first { $0.number == 1 })
        #expect(carried.ciState == .failure, "no lookup this pass is not a change")
        #expect(carried.reviewState == .approved)

        // Back inside the window: the same failure and approval are not news.
        let third = try await client.openPullRequests(AuditFixtures.repo, detailLimit: 1, previous: second)
        let events = GitHubEventDiff.events(from: second, to: third)
        #expect(!events.contains(.ciFailed(prID: "octo/app#1")))
        #expect(!events.contains(.approved(prID: "octo/app#1")))

        // And the alert a dismissal is tied to never left, so it stays dismissed.
        var dismissals = GitHubAlertDismissals()
        let alert = GitHubAttention.ciFailing(carried).alertID
        dismissals.dismiss(alert)
        for pass in [second, third] {
            let present = Set(pass.filter { $0.ciState == .failure }.map { GitHubAttention.ciFailing($0).alertID })
            dismissals.reconcile(present: present, isObservable: { _ in true })
        }
        #expect(dismissals.isDismissed(alert))
    }

    @Test("Without the previous result the old behaviour holds: no detail, no state")
    func withoutPrevious() async throws {
        let fake = AuditTransport()
        fake.on("/repos/octo/app/pulls", body: AuditFixtures.list([AuditFixtures.pull(2, sha: "bbb"), AuditFixtures.pull(1, sha: "aaa")]))
        fake.on("/repos/octo/app/pulls/2/reviews", body: "[]")
        fake.on("/repos/octo/app/commits/bbb/check-runs", body: AuditFixtures.checksPassed)

        let pulls = try await client(fake).openPullRequests(AuditFixtures.repo, detailLimit: 1)

        #expect(pulls.first { $0.number == 1 }?.ciState == .unknown)
        #expect(pulls.first { $0.number == 1 }?.reviewState == GitHubReviewState.none)
    }

    @Test("A new head commit drops what was known about the old one")
    func newCommitIsNotCarried() async throws {
        let fake = AuditTransport()
        fake.on("/repos/octo/app/pulls", body: AuditFixtures.list([AuditFixtures.pull(2, sha: "bbb"), AuditFixtures.pull(1, sha: "pushed-again")]))
        fake.on("/repos/octo/app/pulls/2/reviews", body: "[]")
        fake.on("/repos/octo/app/commits/bbb/check-runs", body: AuditFixtures.checksPassed)
        let previous = [AuditFixtures.pullRequest(1, sha: "aaa", review: .approved, ci: .failure)]

        let pulls = try await client(fake).openPullRequests(AuditFixtures.repo, detailLimit: 1, previous: previous)

        let pushed = try #require(pulls.first { $0.number == 1 })
        #expect(pushed.ciState == .unknown)
        #expect(pushed.reviewState == GitHubReviewState.none)
    }

    @Test("A check or review lookup that fails once keeps the last known state")
    func failedLookupKeepsState() async throws {
        let fake = AuditTransport()
        fake.on("/repos/octo/app/pulls", body: AuditFixtures.list([AuditFixtures.pull(1, sha: "aaa")]))
        fake.on("/repos/octo/app/pulls/1/reviews", status: 502, body: "{}")
        fake.on("/repos/octo/app/commits/aaa/check-runs", status: 502, body: "{}")
        let previous = [AuditFixtures.pullRequest(1, sha: "aaa", review: .changesRequested, ci: .failure)]

        let pulls = try await client(fake).openPullRequests(AuditFixtures.repo, detailLimit: 5, previous: previous)

        #expect(pulls.first?.ciState == .failure)
        #expect(pulls.first?.reviewState == .changesRequested)
        #expect(GitHubEventDiff.events(from: previous, to: pulls).isEmpty)
    }

    @Test("A lookup that answers always wins over what was carried")
    func freshAnswerWins() async throws {
        let fake = AuditTransport()
        fake.on("/repos/octo/app/pulls", body: AuditFixtures.list([AuditFixtures.pull(1, sha: "aaa")]))
        fake.on("/repos/octo/app/pulls/1/reviews", body: "[]")
        fake.on("/repos/octo/app/commits/aaa/check-runs", body: AuditFixtures.checksPassed)
        let previous = [AuditFixtures.pullRequest(1, sha: "aaa", review: .approved, ci: .failure)]

        let pulls = try await client(fake).openPullRequests(AuditFixtures.repo, detailLimit: 5, previous: previous)

        #expect(pulls.first?.ciState == .success, "a re-run that passed on the same commit is reported")
        #expect(pulls.first?.reviewState == GitHubReviewState.none, "a dismissed approval is reported")
    }

    @Test("Review state: an approval or change request stands, a pending request is the list's to report")
    func reviewCarryRules() {
        let listed = AuditFixtures.pullRequest(1, review: .none)
        let requested = AuditFixtures.pullRequest(1, review: .reviewRequired)

        #expect(listed.carryingReviewState(from: AuditFixtures.pullRequest(1, review: .approved)).reviewState == .approved)
        #expect(requested.carryingReviewState(from: AuditFixtures.pullRequest(1, review: .changesRequested)).reviewState == .changesRequested)
        #expect(listed.carryingReviewState(from: AuditFixtures.pullRequest(1, review: .commented)).reviewState == .commented)
        #expect(requested.carryingReviewState(from: AuditFixtures.pullRequest(1, review: .commented)).reviewState == .reviewRequired)
        // The list knows pending requests itself: one withdrawn is gone.
        #expect(listed.carryingReviewState(from: AuditFixtures.pullRequest(1, review: .reviewRequired)).reviewState == GitHubReviewState.none)
        // Another pull request, another commit, or no commit at all: nothing carries.
        #expect(listed.carryingReviewState(from: AuditFixtures.pullRequest(2, review: .approved)).reviewState == GitHubReviewState.none)
        #expect(listed.carryingReviewState(from: AuditFixtures.pullRequest(1, sha: "other", review: .approved)).reviewState == GitHubReviewState.none)
        let noSha = AuditFixtures.pullRequest(1, sha: nil)
        #expect(noSha.carryingReviewState(from: AuditFixtures.pullRequest(1, sha: nil, review: .approved)).reviewState == GitHubReviewState.none)
        #expect(noSha.carryingCIState(from: AuditFixtures.pullRequest(1, sha: nil, ci: .failure)).ciState == .unknown)
    }

    @Test("A merge conflict stays reported while GitHub has no new verdict for the same commit")
    func mergeStateCarry() {
        let conflicted = AuditFixtures.pullRequest(1, mergeable: "dirty")

        // No lookup this pass, a failed one, and GitHub still recomputing.
        let unanswered = AuditFixtures.pullRequest(1, mergeable: nil).carryingMergeState(from: conflicted)
        let recomputing = AuditFixtures.pullRequest(1, mergeable: "unknown").carryingMergeState(from: conflicted)
        #expect(unanswered.mergeability == .conflicts)
        #expect(recomputing.mergeability == .conflicts)
        #expect(!GitHubEventDiff.events(from: [conflicted], to: [unanswered]).contains(.mergeConflict(prID: "octo/app#1")))
        #expect(!GitHubEventDiff.events(from: [unanswered], to: [conflicted]).contains(.mergeConflict(prID: "octo/app#1")))

        // A real answer wins, and a new commit starts over.
        #expect(AuditFixtures.pullRequest(1, mergeable: "clean").carryingMergeState(from: conflicted).mergeability == .ready)
        #expect(AuditFixtures.pullRequest(1, sha: "new", mergeable: nil).carryingMergeState(from: conflicted).mergeableState == nil)

        let list = GitHubPullRequest.carryingMergeStates(
            [AuditFixtures.pullRequest(1), AuditFixtures.pullRequest(2)],
            from: [conflicted]
        )
        #expect(list.map(\.mergeableState) == ["dirty", nil])
        #expect(GitHubPullRequest.carryingMergeStates([AuditFixtures.pullRequest(1)], from: []).first?.mergeableState == nil)
    }
}

@Suite("Audit 1.0.7: the ETag cache holds a full refresh")
struct Audit107GitHubCacheTests {
    private func entry(_ tag: String, bytes: Int = 8) -> GitHubResponseCache.Entry {
        GitHubResponseCache.Entry(etag: tag, body: Data(repeating: 0x20, count: bytes))
    }

    @Test("A pass over 100 repositories fits, where 256 entries could not hold it")
    func holdsARealisticSelection() {
        let cache = GitHubResponseCache()
        // 100 repositories at 16 URLs each, the most a full pass asks for.
        let keys = (0..<1_600).map { "https://api.github.com/repos/octo/app\($0 / 16)/url\($0 % 16)" }
        for key in keys { cache.store(entry("v1"), for: key) }

        #expect(GitHubResponseCache.capacity >= 1_600)
        #expect(cache.count == keys.count)
        #expect(keys.allSatisfy { cache.entry(for: $0) != nil }, "every URL of the pass is still there for the next one")
    }

    @Test("The second pass over many repositories is answered 304 throughout")
    func secondPassIsConditional() async throws {
        let fake = AuditTransport()
        let repositories = (0..<400).map { GitRemote(host: "github.com", owner: "octo", name: "app\($0)") }
        for repository in repositories {
            fake.on("/repos/octo/\(repository.name)/actions/runs", body: #"{"total_count": 0, "workflow_runs": []}"#, etag: #""runs-\#(repository.name)""#)
        }
        let client = GitHubClient(credential: GitHubCredential(token: "test-token", source: .personalAccessToken), transport: fake.transport)

        for repository in repositories { _ = try await client.workflowRuns(repository) }
        #expect(fake.notModifiedCount == 0)
        for repository in repositories { _ = try await client.workflowRuns(repository) }

        #expect(fake.notModifiedCount == repositories.count, "with 256 entries none of these came back 304")
        let secondPass = fake.requests.suffix(repositories.count)
        #expect(secondPass.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") != nil })
    }

    @Test("When full, the least recently used entry leaves, not the one asked for every refresh")
    func evictsLeastRecentlyUsed() {
        let cache = GitHubResponseCache(capacity: 3, byteLimit: 1_024)
        cache.store(entry("a"), for: "runs")
        cache.store(entry("b"), for: "old-commit-checks")
        cache.store(entry("c"), for: "pulls")
        // A refresh asks for the lists again; the replaced commit's checks are never asked for.
        #expect(cache.entry(for: "runs")?.etag == "a")
        #expect(cache.entry(for: "pulls")?.etag == "c")

        cache.store(entry("d"), for: "new-commit-checks")

        #expect(cache.count == 3)
        #expect(cache.entry(for: "old-commit-checks") == nil)
        #expect(cache.entry(for: "runs") != nil)
        #expect(cache.entry(for: "pulls") != nil)
        #expect(cache.entry(for: "new-commit-checks") != nil)
    }

    @Test("Stored bodies stay within the byte budget")
    func byteBudget() {
        let cache = GitHubResponseCache(capacity: 100, byteLimit: 100)
        cache.store(entry("a", bytes: 40), for: "a")
        cache.store(entry("b", bytes: 40), for: "b")
        cache.store(entry("c", bytes: 40), for: "c")
        #expect(cache.entry(for: "a") == nil, "the oldest made room")
        #expect(cache.entry(for: "b") != nil)
        #expect(cache.entry(for: "c") != nil)

        // Replacing an entry counts its new size, not both.
        cache.store(entry("b2", bytes: 60), for: "b")
        #expect(cache.entry(for: "b")?.etag == "b2")
        #expect(cache.entry(for: "c") != nil)

        // A body larger than the whole budget is skipped and evicts nothing else.
        cache.store(entry("huge", bytes: 500), for: "huge")
        #expect(cache.entry(for: "huge") == nil)
        #expect(cache.count == 2)
    }
}

@Suite("Audit 1.0.7: failed lookups wait before they are repeated")
struct Audit107GitHubLookupBackoffTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A failure is left alone for the interval and asked again after it")
    func skipsThenAsksAgain() {
        var backoff = GitHubLookupBackoff(interval: 30 * 60)
        #expect(!backoff.shouldSkip("octo/private", at: start), "never asked: ask")

        backoff.recordFailure("octo/private", at: start)

        #expect(backoff.shouldSkip("octo/private", at: start.addingTimeInterval(60)))
        #expect(backoff.shouldSkip("octo/private", at: start.addingTimeInterval(29 * 60)))
        #expect(!backoff.shouldSkip("octo/private", at: start.addingTimeInterval(30 * 60)), "not cached for good")
        #expect(!backoff.shouldSkip("octo/other", at: start.addingTimeInterval(60)), "other keys are unaffected")
    }

    @Test("A success, a reset, or a clock set back all let the lookup through")
    func clears() {
        var backoff = GitHubLookupBackoff(interval: 300)
        backoff.recordFailure("/work/not-a-repo-yet", at: start)
        backoff.recordFailure("/work/other", at: start)

        backoff.recordSuccess("/work/not-a-repo-yet")
        #expect(!backoff.shouldSkip("/work/not-a-repo-yet", at: start.addingTimeInterval(1)))
        #expect(backoff.shouldSkip("/work/other", at: start.addingTimeInterval(1)))
        #expect(!backoff.shouldSkip("/work/other", at: start.addingTimeInterval(-3_600)))

        backoff.reset()
        #expect(!backoff.shouldSkip("/work/other", at: start.addingTimeInterval(1)))
    }
}

/// Returns scripted results keyed by the argument list.
private final class AuditCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[String]: CommandResult] = [:]

    func stub(_ arguments: [String], _ result: CommandResult) {
        lock.withLock { results[arguments] = result }
    }

    func run(_ executable: String, _ arguments: [String], workingDirectory: String?, timeout: TimeInterval) async -> CommandResult {
        lock.withLock { results[arguments] ?? CommandResult(status: 1, stderr: "unexpected command") }
    }
}

private struct AuditTokenStore: GitHubTokenStoring {
    let token: String?
    func read() throws -> String? { token }
    func save(_ token: String) throws {}
    func delete() throws {}
}

@Suite("Audit 1.0.7: a rejected stored token does not hide the GitHub CLI")
struct Audit107GitHubCredentialFallbackTests {
    /// A stand-in `gh` that exists and is executable; the fake runner never launches it.
    private func makeExecutable() throws -> (directory: URL, path: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overhead-audit-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("gh").path
        FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o755])
        return (directory, path)
    }

    private func makeResolver(stored: String?, cliToken: String?, gh: String) -> GitHubCredentialResolver {
        let runner = AuditCommandRunner()
        if let cliToken {
            runner.stub(["auth", "token", "--hostname", "github.com"], CommandResult(status: 0, stdout: cliToken + "\n"))
            runner.stub(["auth", "status", "--hostname", "github.com"], CommandResult(status: 0, stdout: "Logged in to github.com account octocat (keyring)\n"))
        }
        return GitHubCredentialResolver(
            tokenStore: AuditTokenStore(token: stored),
            cli: GitHubCLI(runner: runner, searchPaths: [gh])
        )
    }

    @Test("After a 401 on the stored token the CLI's credential is offered")
    func storedTokenRejected() async throws {
        let gh = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: gh.directory) }
        let resolver = makeResolver(stored: "revoked-token", cliToken: "cli-token", gh: gh.path)

        let first = try #require(await resolver.resolve())
        #expect(first.source == .personalAccessToken, "the stored token is still tried first")

        let fallback = try #require(await resolver.fallback(afterRejecting: first))
        #expect(fallback.source == .githubCLI)
        #expect(fallback.token == "cli-token")
        #expect(fallback.account == "octocat")

        // From then on the dead token is skipped rather than rejected again.
        let later = try #require(await resolver.resolve(skippingStoredToken: true))
        #expect(later.source == .githubCLI)
    }

    @Test("Nothing stands behind the CLI's own token, a missing CLI, or the same token again")
    func noFallback() async throws {
        let gh = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: gh.directory) }

        let cliOnly = makeResolver(stored: nil, cliToken: "cli-token", gh: gh.path)
        let cliCredential = try #require(await cliOnly.resolve())
        let behindCLI = await cliOnly.fallback(afterRejecting: cliCredential)
        #expect(behindCLI == nil)

        let signedOut = makeResolver(stored: "revoked-token", cliToken: nil, gh: gh.path)
        let stored = try #require(await signedOut.resolve())
        let withoutCLI = await signedOut.fallback(afterRejecting: stored)
        let skipped = await signedOut.resolve(skippingStoredToken: true)
        #expect(withoutCLI == nil)
        #expect(skipped == nil)

        // The CLI holds the very token that was just rejected: trying it again proves nothing.
        let same = makeResolver(stored: "revoked-token", cliToken: "revoked-token", gh: gh.path)
        let rejected = try #require(await same.resolve())
        let sameAgain = await same.fallback(afterRejecting: rejected)
        #expect(sameAgain == nil)
    }

    @Test("A credential still never prints its token")
    func fallbackStaysRedacted() async throws {
        let gh = try makeExecutable()
        defer { try? FileManager.default.removeItem(at: gh.directory) }
        let resolver = makeResolver(stored: "revoked-token", cliToken: "cli-secret-token", gh: gh.path)
        let rejected = try #require(await resolver.resolve())
        let fallback = try #require(await resolver.fallback(afterRejecting: rejected))

        #expect(!"\(fallback)".contains("cli-secret-token"))
        #expect(!String(reflecting: fallback).contains("cli-secret-token"))
    }
}
