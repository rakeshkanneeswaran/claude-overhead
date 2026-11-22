import Foundation
import Testing
@testable import ChimloCore

/// Serves canned responses by URL path and records every request. Each path
/// holds a queue of replies; the last one repeats. Unknown paths get 404.
private final class FakeGitHubTransport: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String]
    }

    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var recorded: [URLRequest] = []
    private var failure: (any Error)?

    func on(_ path: String, status: Int = 200, body: String, headers: [String: String] = [:]) {
        lock.withLock {
            routes[path, default: []].append(Reply(status: status, body: body, headers: headers))
        }
    }

    func fail(with error: any Error) {
        lock.withLock { failure = error }
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path == path }
    }

    var transport: GitHubTransport {
        { [self] request in try self.respond(to: request) }
    }

    private func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let reply = try lock.withLock { () throws -> Reply in
            recorded.append(request)
            if let failure { throw failure }
            let path = request.url?.path ?? ""
            guard var queue = routes[path], let first = queue.first else {
                return Reply(status: 404, body: #"{"message":"Not Found"}"#, headers: [:])
            }
            if queue.count > 1 {
                queue.removeFirst()
                routes[path] = queue
            }
            return first
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else { throw URLError(.badServerResponse) }
        return (Data(reply.body.utf8), response)
    }
}

private enum Fixtures {
    static let repo = GitRemote(host: "github.com", owner: "octo", name: "app")

    static let pulls = """
    [
      {
        "url": "https://api.github.com/repos/octo/app/pulls/42",
        "id": 1001, "node_id": "PR_1", "number": 42, "state": "open", "locked": false,
        "title": "Add notch countdown", "html_url": "https://github.com/octo/app/pull/42",
        "user": {"login": "alice", "id": 1, "type": "User"},
        "body": "Adds a countdown.", "created_at": "2026-11-18T09:00:00Z", "updated_at": "2026-11-20T10:00:00Z",
        "closed_at": null, "merged_at": null, "draft": false,
        "requested_reviewers": [{"login": "carol", "id": 3}], "requested_teams": [],
        "labels": [], "milestone": null,
        "head": {"label": "octo:feature/countdown", "ref": "feature/countdown", "sha": "aaa111",
                 "user": {"login": "octo"}, "repo": {"id": 9, "name": "app", "full_name": "octo/app"}},
        "base": {"label": "octo:main", "ref": "main", "sha": "base000",
                 "user": {"login": "octo"}, "repo": {"id": 9, "name": "app", "full_name": "octo/app"}},
        "author_association": "MEMBER", "auto_merge": null
      },
      {
        "url": "https://api.github.com/repos/octo/app/pulls/41",
        "id": 1000, "number": 41, "state": "open",
        "title": "Fix typo", "html_url": "https://github.com/octo/app/pull/41",
        "user": {"login": "dave"}, "updated_at": "2026-11-19T08:30:00Z",
        "merged_at": null, "draft": true,
        "requested_reviewers": [], "requested_teams": [{"name": "Core", "slug": "core"}],
        "head": {"ref": "fix-typo", "sha": "ccc222", "repo": {"full_name": "dave/app"}},
        "base": {"ref": "main", "sha": "base000", "repo": {"full_name": "octo/app"}}
      }
    ]
    """

    static let reviews42 = """
    [
      {"id": 1, "user": {"login": "bob"}, "body": "", "state": "COMMENTED", "submitted_at": "2026-11-19T09:00:00Z"},
      {"id": 2, "user": {"login": "bob"}, "body": "LGTM", "state": "APPROVED", "submitted_at": "2026-11-19T10:00:00Z"}
    ]
    """

    static let checksSuccess = """
    {"total_count": 2, "check_runs": [
      {"id": 1, "name": "build", "status": "completed", "conclusion": "success", "head_sha": "aaa111"},
      {"id": 2, "name": "lint", "status": "completed", "conclusion": "skipped", "head_sha": "aaa111"}
    ]}
    """

    static let checksRunning = """
    {"total_count": 2, "check_runs": [
      {"id": 3, "name": "build", "status": "in_progress", "conclusion": null},
      {"id": 4, "name": "lint", "status": "completed", "conclusion": "success"}
    ]}
    """

    static let singlePull = """
    {
      "number": 42, "state": "open", "title": "Add notch countdown",
      "html_url": "https://github.com/octo/app/pull/42", "user": {"login": "alice"},
      "updated_at": "2026-11-20T10:00:00Z", "merged_at": null, "merged": false, "draft": false,
      "mergeable": false, "mergeable_state": "dirty", "comments": 3, "review_comments": 2,
      "requested_reviewers": [], "requested_teams": [],
      "head": {"ref": "feature/countdown", "sha": "aaa111", "repo": {"full_name": "octo/app"}},
      "base": {"ref": "main", "repo": {"full_name": "octo/app"}}
    }
    """

    static let runs = """
    {"total_count": 2, "workflow_runs": [
      {"id": 101, "name": "CI", "display_title": "Add notch countdown", "run_number": 12,
       "event": "pull_request", "status": "completed", "conclusion": "failure",
       "head_branch": "feature/countdown", "head_sha": "aaa111",
       "created_at": "2026-11-20T10:00:00Z", "run_started_at": "2026-11-20T10:00:05Z",
       "updated_at": "2026-11-20T10:04:05Z", "html_url": "https://github.com/octo/app/actions/runs/101",
       "repository": {"id": 9, "full_name": "octo/app"}},
      {"id": 102, "name": null, "display_title": "Nightly", "event": "schedule",
       "status": "in_progress", "conclusion": null, "head_branch": "main", "head_sha": "ddd444",
       "created_at": "2026-11-20T11:00:00Z", "run_started_at": "2026-11-20T11:00:02Z",
       "updated_at": "2026-11-20T11:01:00Z", "html_url": "https://github.com/octo/app/actions/runs/102"}
    ]}
    """

    static let search = """
    {"total_count": 2, "incomplete_results": false, "items": [
      {"url": "https://api.github.com/repos/octo/lib/issues/7", "number": 7, "title": "Bump dependencies",
       "html_url": "https://github.com/octo/lib/pull/7", "user": {"login": "renovate[bot]"},
       "state": "open", "draft": false, "comments": 4, "updated_at": "2026-11-21T12:00:00Z",
       "repository_url": "https://api.github.com/repos/octo/lib",
       "pull_request": {"url": "https://api.github.com/repos/octo/lib/pulls/7", "merged_at": null}},
      {"number": 8, "title": "A plain issue", "html_url": "https://github.com/octo/lib/issues/8",
       "state": "open", "repository_url": "https://api.github.com/repos/octo/lib"}
    ]}
    """
}

@Suite("GitHub client")
struct GitHubClientTests {
    private let credential = GitHubCredential(token: "ghp_test_token_value", source: .personalAccessToken)

    private func client(_ fake: FakeGitHubTransport) -> GitHubClient {
        GitHubClient(credential: credential, transport: fake.transport)
    }

    @Test("Sends the bearer token and GitHub's recommended headers")
    func headers() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/user", body: #"{"login": "octocat", "id": 1}"#)

        let login = try await client(fake).viewerLogin()
        let request = try #require(fake.requests.first)
        #expect(login == "octocat")
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_test_token_value")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeOverhead")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("Open pull requests decode with review and CI state")
    func openPullRequests() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/pulls", body: Fixtures.pulls)
        fake.on("/repos/octo/app/pulls/42/reviews", body: Fixtures.reviews42)
        fake.on("/repos/octo/app/pulls/41/reviews", body: "[]")
        fake.on("/repos/octo/app/commits/aaa111/check-runs", body: Fixtures.checksSuccess)
        fake.on("/repos/octo/app/commits/ccc222/check-runs", body: Fixtures.checksRunning)

        let prs = try await client(fake).openPullRequests(Fixtures.repo)
        #expect(prs.count == 2)

        let first = try #require(prs.first)
        #expect(first.id == "octo/app#42")
        #expect(first.title == "Add notch countdown")
        #expect(first.url == "https://github.com/octo/app/pull/42")
        #expect(first.author == "alice")
        #expect(first.headRef == "feature/countdown")
        #expect(first.headRepository == "octo/app")
        #expect(first.headSha == "aaa111")
        #expect(first.baseRef == "main")
        #expect(!first.isDraft)
        #expect(first.state == "open")
        #expect(!first.merged)
        #expect(first.updatedAt == (try? Date("2026-11-20T10:00:00Z", strategy: .iso8601)))
        #expect(first.requestedReviewers == ["carol"])
        // bob approved, so carol's outstanding request no longer blocks.
        #expect(first.reviewState == .approved)
        #expect(first.ciState == .success)
        #expect(first.mergeableState == nil)
        #expect(first.commentCount == nil)

        let fork = try #require(prs.last)
        #expect(fork.headRepository == "dave/app")
        #expect(fork.isDraft)
        // Only a team review is requested.
        #expect(fork.requestedReviewers.isEmpty)
        #expect(fork.reviewState == .reviewRequired)
        #expect(fork.ciState == .inProgress)

        let listRequest = try #require(fake.requests(to: "/repos/octo/app/pulls").first)
        let query = listRequest.url?.query(percentEncoded: true) ?? ""
        #expect(query.contains("state=open"))
        #expect(query.contains("per_page=30"))
    }

    @Test("Only the first ten pull requests get review and check lookups")
    func detailLimit() async throws {
        let pulls = (1...12).map { number in
            """
            {"number": \(number), "title": "PR \(number)", "html_url": "https://github.com/octo/app/pull/\(number)",
             "state": "open", "user": {"login": "alice"}, "requested_reviewers": [],
             "head": {"ref": "branch-\(number)", "sha": "sha\(number)", "repo": {"full_name": "octo/app"}},
             "base": {"ref": "main", "repo": {"full_name": "octo/app"}}}
            """
        }
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/pulls", body: "[\(pulls.joined(separator: ","))]")
        for number in 1...12 {
            fake.on("/repos/octo/app/pulls/\(number)/reviews", body: "[]")
            fake.on("/repos/octo/app/commits/sha\(number)/check-runs", body: Fixtures.checksSuccess)
        }

        let prs = try await client(fake).openPullRequests(Fixtures.repo)
        let reviewRequests = fake.requests.filter { $0.url?.path.hasSuffix("/reviews") == true }
        let checkRequests = fake.requests.filter { $0.url?.path.hasSuffix("/check-runs") == true }
        #expect(prs.count == 12)
        #expect(reviewRequests.count == 10)
        #expect(checkRequests.count == 10)
        #expect(prs[9].ciState == .success)
        #expect(prs[10].ciState == .unknown)
    }

    @Test("A check lookup without permission degrades instead of failing the list")
    func degradesOnForbiddenChecks() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/pulls", body: Fixtures.pulls)
        fake.on("/repos/octo/app/pulls/42/reviews", body: Fixtures.reviews42)
        fake.on("/repos/octo/app/pulls/41/reviews", body: "[]")
        fake.on(
            "/repos/octo/app/commits/aaa111/check-runs",
            status: 403,
            body: #"{"message": "Resource not accessible by personal access token"}"#
        )

        let prs = try await client(fake).openPullRequests(Fixtures.repo)
        #expect(prs.first?.ciState == .unknown)
        #expect(prs.first?.reviewState == .approved)
        // Unrouted check-runs for #41 return 404, which also degrades.
        #expect(prs.last?.ciState == .unknown)
    }

    @Test("Hitting the rate limit mid-list fails the whole call")
    func rateLimitDuringDetails() async {
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/pulls", body: Fixtures.pulls)
        fake.on(
            "/repos/octo/app/pulls/42/reviews",
            status: 403,
            body: #"{"message": "API rate limit exceeded"}"#,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"]
        )
        await #expect(throws: GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000))) {
            try await client(fake).openPullRequests(Fixtures.repo)
        }
    }

    @Test("A single pull request adds merge state and comment count")
    func singlePullRequest() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/pulls/42", body: Fixtures.singlePull)
        fake.on("/repos/octo/app/pulls/42/reviews", body: "[]")
        fake.on("/repos/octo/app/commits/aaa111/check-runs", body: Fixtures.checksRunning)

        let pr = try await client(fake).pullRequest(Fixtures.repo, number: 42)
        #expect(pr.mergeableState == "dirty")
        #expect(pr.commentCount == 5)
        #expect(pr.reviewState == .none)
        #expect(pr.ciState == .inProgress)
    }

    @Test("A merged pull request decodes as closed and merged")
    func mergedPullRequest() async throws {
        let merged = Fixtures.singlePull
            .replacingOccurrences(of: #""state": "open""#, with: #""state": "closed""#)
            .replacingOccurrences(of: #""merged_at": null, "merged": false"#, with: #""merged_at": "2026-11-21T00:00:00Z", "merged": true"#)
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/pulls/42", body: merged)

        let pr = try await client(fake).pullRequest(Fixtures.repo, number: 42)
        #expect(pr.state == "closed")
        #expect(pr.merged)
        #expect(!pr.isOpen)
    }

    @Test("Workflow runs decode with CI state and duration")
    func workflowRuns() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/actions/runs", body: Fixtures.runs)

        let runs = try await client(fake).workflowRuns(Fixtures.repo, branch: "feature/countdown", limit: 5)
        #expect(runs.count == 2)
        let failed = try #require(runs.first)
        #expect(failed.id == 101)
        #expect(failed.repository == "octo/app")
        #expect(failed.name == "CI")
        #expect(failed.branch == "feature/countdown")
        #expect(failed.headSha == "aaa111")
        #expect(failed.event == "pull_request")
        #expect(failed.ciState == .failure)
        #expect(failed.duration == 240)
        #expect(failed.url == "https://github.com/octo/app/actions/runs/101")

        let running = try #require(runs.last)
        #expect(running.name == "Nightly")
        #expect(running.repository == "octo/app")
        #expect(running.ciState == .inProgress)
        #expect(running.duration == nil)

        let query = fake.requests.first?.url?.query(percentEncoded: true) ?? ""
        #expect(query.contains("per_page=5"))
        #expect(query.contains("branch=feature%2Fcountdown"))
    }

    @Test("Branch names are fully percent-encoded in the query")
    func branchEncoding() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/repos/octo/app/actions/runs", body: #"{"total_count": 0, "workflow_runs": []}"#)

        let runs = try await client(fake).workflowRuns(Fixtures.repo, branch: "feat/a&b+c#d")
        let query = fake.requests.first?.url?.query(percentEncoded: true) ?? ""
        #expect(runs.isEmpty)
        #expect(query.contains("branch=feat%2Fa%26b%2Bc%23d"))
        #expect(query.contains("per_page=10"))
    }

    @Test("Review requests come from search and skip plain issues")
    func reviewRequests() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/search/issues", body: Fixtures.search, headers: ["X-RateLimit-Resource": "search", "X-RateLimit-Remaining": "29"])

        let prs = try await client(fake).reviewRequestsForViewer()
        #expect(prs.count == 1)
        let pr = try #require(prs.first)
        #expect(pr.id == "octo/lib#7")
        #expect(pr.author == "renovate[bot]")
        #expect(pr.reviewState == .reviewRequired)
        #expect(pr.commentCount == 4)
        #expect(!pr.merged)

        let query = fake.requests.first?.url?.query(percentEncoded: false) ?? ""
        #expect(query.contains("review-requested:@me"))
        #expect(query.contains("is:pr"))
        #expect(query.contains("is:open"))
    }

    @Test("Error statuses map to typed errors")
    func errorMapping() async {
        let cases: [(Int, String, [String: String], GitHubError)] = [
            (401, #"{"message": "Bad credentials"}"#, [:], .unauthorized),
            (404, #"{"message": "Not Found"}"#, [:], .notFound),
            (
                403, #"{"message": "API rate limit exceeded"}"#,
                ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"],
                .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000))
            ),
            (
                429, #"{"message": "too many"}"#,
                ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000100"],
                .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_100))
            ),
            (403, #"{"message": "You have exceeded a secondary rate limit."}"#, [:], .rateLimited(resetAt: nil)),
            (
                403, #"{"message": "Resource not accessible by personal access token"}"#,
                ["X-RateLimit-Remaining": "4000"],
                .forbidden("Resource not accessible by personal access token")
            ),
            (403, "not json", [:], .forbidden(nil)),
            (500, "", [:], .unexpectedStatus(500)),
        ]
        for (status, body, headers, expected) in cases {
            let fake = FakeGitHubTransport()
            fake.on("/user", status: status, body: body, headers: headers)
            await #expect(throws: expected) {
                try await client(fake).viewerLogin()
            }
        }
    }

    @Test("Retry-After sets the reset time for secondary rate limits")
    func retryAfter() async {
        let fake = FakeGitHubTransport()
        fake.on("/user", status: 429, body: "{}", headers: ["Retry-After": "60"])
        let before = Date()
        do {
            _ = try await client(fake).viewerLogin()
            Issue.record("Expected a rate-limit error")
        } catch let error as GitHubError {
            guard case .rateLimited(let resetAt?) = error else {
                Issue.record("Unexpected error \(error)")
                return
            }
            let delay = resetAt.timeIntervalSince(before)
            #expect(delay >= 59 && delay <= 65)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Transport and decoding failures map to network and decoding errors")
    func transportAndDecoding() async {
        let offline = FakeGitHubTransport()
        offline.fail(with: URLError(.notConnectedToInternet))
        await #expect(throws: GitHubError.self) {
            try await client(offline).viewerLogin()
        }
        do {
            _ = try await client(offline).viewerLogin()
        } catch let error as GitHubError {
            guard case .network = error else {
                Issue.record("Expected a network error, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        let garbled = FakeGitHubTransport()
        garbled.on("/repos/octo/app/pulls", body: #"[{"number": "not a number"}]"#)
        do {
            _ = try await client(garbled).openPullRequests(Fixtures.repo)
            Issue.record("Expected a decoding error")
        } catch let error as GitHubError {
            guard case .decoding = error else {
                Issue.record("Expected a decoding error, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("A 304 reuses the cached body and sends the stored ETag")
    func etagReuse() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/user", body: #"{"login": "octocat"}"#, headers: ["ETag": #"W/"abc123""#])
        fake.on("/user", status: 304, body: "")

        let client = client(fake)
        let first = try await client.viewerLogin()
        let second = try await client.viewerLogin()
        let requests = fake.requests
        #expect(first == "octocat")
        #expect(second == "octocat")
        #expect(requests.count == 2)
        #expect(requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == #"W/"abc123""#)
    }

    @Test("Copies of a client share the ETag cache")
    func sharedCacheAcrossCopies() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/user", body: #"{"login": "octocat"}"#, headers: ["ETag": #""v1""#])
        fake.on("/user", status: 304, body: "")

        let original = client(fake)
        let copy = original
        _ = try await original.viewerLogin()
        let login = try await copy.viewerLogin()
        #expect(login == "octocat")
        #expect(fake.requests.last?.value(forHTTPHeaderField: "If-None-Match") == #""v1""#)
    }

    @Test("The core rate limit is tracked; search limits are not mixed in")
    func rateLimitTracking() async throws {
        let fake = FakeGitHubTransport()
        fake.on("/user", body: #"{"login": "octocat"}"#, headers: [
            "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "4999",
            "X-RateLimit-Reset": "1800000000",
            "X-RateLimit-Resource": "core",
        ])
        fake.on("/search/issues", body: Fixtures.search, headers: [
            "X-RateLimit-Limit": "30",
            "X-RateLimit-Remaining": "29",
            "X-RateLimit-Resource": "search",
        ])

        let client = client(fake)
        #expect(client.lastRateLimit == nil)
        _ = try await client.viewerLogin()
        _ = try await client.reviewRequestsForViewer()
        #expect(client.lastRateLimit == GitHubRateLimit(
            limit: 5000,
            remaining: 4999,
            resetAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    @Test("Enterprise remotes use the /api/v3 base URL")
    func enterpriseBaseURL() async throws {
        let remote = GitRemote(host: "ghe.corp.internal", owner: "platform", name: "api")
        #expect(GitHubClient.apiBaseURL(for: remote)?.absoluteString == "https://ghe.corp.internal/api/v3")
        #expect(GitHubClient.apiBaseURL(for: Fixtures.repo) == GitHubClient.defaultBaseURL)

        let fake = FakeGitHubTransport()
        fake.on("/api/v3/user", body: #"{"login": "enterprise-user"}"#)
        let baseURL = try #require(GitHubClient.apiBaseURL(for: remote))
        let client = GitHubClient(credential: credential, baseURL: baseURL, transport: fake.transport)
        let login = try await client.viewerLogin()
        #expect(login == "enterprise-user")
        #expect(fake.requests.first?.url?.absoluteString == "https://ghe.corp.internal/api/v3/user")
    }

    @Test("A client's textual forms never contain the token")
    func clientRedaction() {
        let fake = FakeGitHubTransport()
        let client = client(fake)
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!String(describing: client).contains("ghp_test_token_value"))
        #expect(!String(reflecting: client).contains("ghp_test_token_value"))
        #expect(!dumped.contains("ghp_test_token_value"))
    }
}
