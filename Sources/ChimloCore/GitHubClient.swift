import Foundation

/// Sends one request. Always injected: Core does no networking itself, so
/// tests never touch the network and the app owns the real URLSession.
public typealias GitHubTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// A small read-only GitHub REST client for pull request and CI status.
///
/// Requests are conditional: each response's ETag is kept in memory and sent
/// back as `If-None-Match`. GitHub does not count a 304 against the rate
/// limit, which is what makes polling a handful of endpoints sustainable.
/// Copies of a client share that cache.
public struct GitHubClient: Sendable {
    public static let defaultBaseURL: URL = {
        guard let url = URL(string: "https://api.github.com") else {
            preconditionFailure("The literal GitHub API URL is valid")
        }
        return url
    }()

    /// Pull requests that also get review and check-run lookups; each costs two
    /// extra requests, so only the most recently updated ones get them.
    public static let detailLimit = 10

    /// The REST root for a remote: api.github.com for GitHub, and the
    /// Enterprise Server convention `https://<host>/api/v3` otherwise.
    public static func apiBaseURL(for remote: GitRemote) -> URL? {
        if remote.isGitHub { return defaultBaseURL }
        var components = URLComponents()
        components.scheme = "https"
        components.host = remote.host
        components.path = "/api/v3"
        return components.url
    }

    private let credential: GitHubCredential
    private let baseURL: URL
    private let transport: GitHubTransport
    private let cache = GitHubResponseCache()

    public init(
        credential: GitHubCredential,
        baseURL: URL = GitHubClient.defaultBaseURL,
        transport: @escaping GitHubTransport
    ) {
        self.credential = credential
        self.baseURL = baseURL
        self.transport = transport
    }

    /// The core rate limit from the most recent response that reported it.
    /// Search responses carry their own, separate limit and do not update it.
    public var lastRateLimit: GitHubRateLimit? { cache.rateLimit }

    public func viewerLogin() async throws -> String {
        let user = try await get(["user"], as: UserDTO.self)
        guard let login = user.login else { throw GitHubError.decoding("missing login") }
        return login
    }

    /// Open pull requests, most recently updated first (up to 30). The first
    /// `detailLimit` also get review and CI state.
    ///
    /// `previous` is the last result for this repository. A pull request that
    /// gets no review or check answer this time (it is past `detailLimit`, or
    /// the lookup failed) keeps what `previous` knew for the same head commit.
    public func openPullRequests(
        _ repo: GitRemote,
        detailLimit: Int = GitHubClient.detailLimit,
        previous: [GitHubPullRequest] = []
    ) async throws -> [GitHubPullRequest] {
        let pulls = try await get(
            ["repos", repo.owner, repo.name, "pulls"],
            query: [("state", "open"), ("sort", "updated"), ("direction", "desc"), ("per_page", "30")],
            as: [PullRequestDTO].self
        )
        var pullRequests = pulls.map { $0.pullRequest(fallbackRepository: repo.fullName) }
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let detailed = max(0, detailLimit)
        // Sequential on purpose: GitHub's secondary rate limits penalize bursts
        // of concurrent requests from one token.
        for index in pullRequests.indices {
            let earlier = known[pullRequests[index].id]
            if index < detailed {
                pullRequests[index] = try await withReviewsAndChecks(pullRequests[index], in: repo, previous: earlier)
            } else if let earlier {
                pullRequests[index] = pullRequests[index]
                    .carryingReviewState(from: earlier)
                    .carryingCIState(from: earlier)
            }
        }
        return pullRequests
    }

    /// One pull request with everything the list omits: merge state and
    /// comment count, plus review and CI state.
    public func pullRequest(_ repo: GitRemote, number: Int) async throws -> GitHubPullRequest {
        let pull = try await get(
            ["repos", repo.owner, repo.name, "pulls", String(number)],
            as: PullRequestDTO.self
        )
        return try await withReviewsAndChecks(pull.pullRequest(fallbackRepository: repo.fullName), in: repo)
    }

    public func workflowRuns(
        _ repo: GitRemote,
        branch: String? = nil,
        limit: Int = 10
    ) async throws -> [GitHubWorkflowRun] {
        let pageSize = min(max(limit, 1), 100)
        var query = [("per_page", String(pageSize))]
        if let branch, !branch.isEmpty {
            query.append(("branch", branch))
        }
        let response = try await get(
            ["repos", repo.owner, repo.name, "actions", "runs"],
            query: query,
            as: WorkflowRunsDTO.self
        )
        return response.workflowRuns
            .prefix(pageSize)
            .map { $0.workflowRun(fallbackRepository: repo.fullName) }
    }

    /// Open pull requests across GitHub that request the viewer's review.
    /// Search results lack branch names (left empty) and CI state; their
    /// review state is `.reviewRequired` by definition. Search has its own
    /// lower rate limit (30 requests a minute), so poll it less often.
    public func reviewRequestsForViewer() async throws -> [GitHubPullRequest] {
        let response = try await get(
            ["search", "issues"],
            query: [
                ("q", "is:pr is:open review-requested:@me archived:false"),
                ("sort", "updated"),
                ("order", "desc"),
                ("per_page", "30"),
            ],
            as: SearchDTO.self
        )
        return response.items.compactMap { $0.model() }
    }

    // MARK: - Repositories

    /// Repositories the viewer can read: their own, ones they collaborate on,
    /// and their organizations', most recently pushed first. Pages of 100, at
    /// most `maxPages` of them, so a huge organization cannot stall a refresh.
    public func viewerRepositories(maxPages: Int = 5) async throws -> [GitHubRepositoryInfo] {
        var results: [GitHubRepositoryInfo] = []
        for page in 1...max(1, maxPages) {
            let batch = try await get(
                ["user", "repos"],
                query: [
                    ("per_page", "100"), ("page", String(page)), ("sort", "pushed"),
                    ("affiliation", "owner,collaborator,organization_member"),
                ],
                as: [RepositoryDTO].self
            )
            results += batch.compactMap(\.info)
            if batch.count < 100 { break }
        }
        return results
    }

    /// One repository by owner and name. GitHub follows renames here too.
    public func repository(_ repo: GitRemote) async throws -> GitHubRepositoryInfo {
        let dto = try await get(["repos", repo.owner, repo.name], as: RepositoryDTO.self)
        guard let info = dto.info else { throw GitHubError.decoding("missing repository id") }
        return info
    }

    /// One repository by its numeric id, which survives renames and transfers.
    public func repository(id: Int64) async throws -> GitHubRepositoryInfo {
        let dto = try await get(["repositories", String(id)], as: RepositoryDTO.self)
        guard let info = dto.info else { throw GitHubError.decoding("missing repository id") }
        return info
    }

    /// Recently merged or closed pull requests (no review or check lookups).
    public func recentlyClosedPullRequests(_ repo: GitRemote, limit: Int = 10) async throws -> [GitHubPullRequest] {
        let pulls = try await get(
            ["repos", repo.owner, repo.name, "pulls"],
            query: [("state", "closed"), ("sort", "updated"), ("direction", "desc"), ("per_page", String(min(max(limit, 1), 30)))],
            as: [PullRequestDTO].self
        )
        return pulls.map { $0.pullRequest(fallbackRepository: repo.fullName) }
    }

    // MARK: - On-demand detail

    /// The jobs of one run, with their steps. Fetched when the owner opens a
    /// run; logs are not downloaded (GitHub serves them from another host and
    /// they can be very large), so each job links to its page instead.
    public func workflowJobs(_ repo: GitRemote, runID: Int) async throws -> [GitHubWorkflowJob] {
        let response = try await get(
            ["repos", repo.owner, repo.name, "actions", "runs", String(runID), "jobs"],
            query: [("per_page", "100")],
            as: JobsDTO.self
        )
        return response.jobs.map(\.job)
    }

    /// One pull request with its description, size, reviews and checks.
    public func pullRequestDetail(_ repo: GitRemote, number: Int) async throws -> GitHubPullRequestDetail {
        let pull = try await get(
            ["repos", repo.owner, repo.name, "pulls", String(number)],
            as: PullRequestDTO.self
        )
        var pullRequest = pull.pullRequest(fallbackRepository: repo.fullName)
        let hasPendingRequests = pullRequest.reviewState == .reviewRequired
        let records = try await tolerant { try await self.reviewRecords(repo, number: number) } ?? []
        pullRequest.reviewState = GitHubReviewState.resolve(reviews: records, hasPendingRequests: hasPendingRequests)
        var checks: [GitHubCheckRun] = []
        if let sha = pullRequest.headSha, !sha.isEmpty,
           let response = try await tolerant({
               try await self.get(["repos", repo.owner, repo.name, "commits", sha, "check-runs"], query: [("per_page", "100")], as: CheckRunsDTO.self)
           }) {
            checks = response.checkRuns.map {
                GitHubCheckRun(id: $0.id ?? 0, name: $0.name ?? "Check", status: $0.status, conclusion: $0.conclusion, url: $0.htmlUrl)
            }
            pullRequest.ciState = CIState.combine(response.checkRuns.map { CIState.from(status: $0.status, conclusion: $0.conclusion) })
        }
        let reviews = records
            .filter { $0.state.uppercased() != "PENDING" }
            .map { GitHubReview(author: $0.login, state: $0.state, submittedAt: $0.submittedAt) }
            .sorted { ($0.submittedAt ?? .distantPast) > ($1.submittedAt ?? .distantPast) }
        return GitHubPullRequestDetail(
            pullRequest: pullRequest,
            body: pull.body,
            additions: pull.additions,
            deletions: pull.deletions,
            changedFiles: pull.changedFiles,
            commits: pull.commits,
            createdAt: pull.createdAt,
            mergedAt: pull.mergedAt,
            closedAt: pull.closedAt,
            reviews: reviews,
            checks: checks,
            mergeable: pull.mergeable
        )
    }

    // MARK: - Writing

    /// Merges a pull request: the only write Overhead ever makes, and only
    /// after the owner confirms. `expectedHeadSha` pins the merge to the commit
    /// the owner looked at; if anyone pushed since, GitHub answers 409 and
    /// nothing is merged.
    public func mergePullRequest(
        _ repo: GitRemote,
        number: Int,
        method: GitHubMergeMethod,
        expectedHeadSha: String?
    ) async throws -> GitHubMergeResult {
        var body: [String: String] = ["merge_method": method.rawValue]
        if let expectedHeadSha, !expectedHeadSha.isEmpty { body["sha"] = expectedHeadSha }
        let data = try await send(
            "PUT",
            ["repos", repo.owner, repo.name, "pulls", String(number), "merge"],
            body: try JSONEncoder().encode(body)
        )
        let response = (try? Self.makeDecoder().decode(MergeDTO.self, from: data))
        return GitHubMergeResult(merged: response?.merged ?? true, sha: response?.sha, message: response?.message)
    }

    // MARK: - Details

    /// Review and check failures other than authentication and rate limiting
    /// degrade to the list's own information instead of failing the whole
    /// list; a fine-grained token without Checks access should still see PRs.
    private func withReviewsAndChecks(
        _ pullRequest: GitHubPullRequest,
        in repo: GitRemote,
        previous: GitHubPullRequest? = nil
    ) async throws -> GitHubPullRequest {
        var updated = pullRequest
        // The DTO mapping marks pending review requests (users or teams) as
        // `.reviewRequired`; the review aggregation needs that fact.
        let hasPendingRequests = pullRequest.reviewState == .reviewRequired
        async let reviews = tolerant {
            try await self.reviewRecords(repo, number: pullRequest.number)
        }
        async let checks = tolerant {
            try await self.combinedCheckState(repo, sha: pullRequest.headSha)
        }
        // A lookup that failed says nothing new, so what was known for this
        // commit stands; otherwise one network hiccup would clear a failure
        // and the next refresh would announce it again.
        if let records = try await reviews {
            updated.reviewState = GitHubReviewState.resolve(reviews: records, hasPendingRequests: hasPendingRequests)
        } else if let previous {
            updated = updated.carryingReviewState(from: previous)
        }
        if let state = try await checks {
            updated.ciState = state
        } else if let previous {
            updated = updated.carryingCIState(from: previous)
        }
        return updated
    }

    private func reviewRecords(_ repo: GitRemote, number: Int) async throws -> [GitHubReviewRecord] {
        let reviews = try await get(
            ["repos", repo.owner, repo.name, "pulls", String(number), "reviews"],
            query: [("per_page", "100")],
            as: [ReviewDTO].self
        )
        return reviews.compactMap { review in
            guard let login = review.user?.login else { return nil }
            return GitHubReviewRecord(login: login, state: review.state, submittedAt: review.submittedAt)
        }
    }

    private func combinedCheckState(_ repo: GitRemote, sha: String?) async throws -> CIState {
        guard let sha, !sha.isEmpty else { return .unknown }
        let response = try await get(
            ["repos", repo.owner, repo.name, "commits", sha, "check-runs"],
            query: [("per_page", "100")],
            as: CheckRunsDTO.self
        )
        return CIState.combine(response.checkRuns.map { CIState.from(status: $0.status, conclusion: $0.conclusion) })
    }

    private func tolerant<T: Sendable>(_ operation: () async throws -> T) async throws -> T? {
        do {
            return try await operation()
        } catch let error as GitHubError {
            switch error {
            case .unauthorized, .rateLimited: throw error
            default: return nil
            }
        }
    }

    // MARK: - Transport

    private func get<T: Decodable>(
        _ path: [String],
        query: [(String, String)] = [],
        as type: T.Type
    ) async throws -> T {
        let data = try await fetch(path, query: query)
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(Self.describe(error))
        }
    }

    private func fetch(_ path: [String], query: [(String, String)]) async throws -> Data {
        guard let url = makeURL(path, query: query) else {
            throw GitHubError.network("Could not build a request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClaudeOverhead", forHTTPHeaderField: "User-Agent")

        let key = url.absoluteString
        let cached = cache.entry(for: key)
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Self.transportError(error)
        }

        let rateLimit = Self.rateLimit(from: response)
        if let rateLimit, Self.isCoreResource(response) {
            cache.record(rateLimit)
        }

        let status = response.statusCode
        switch status {
        case 200..<300:
            if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                cache.store(GitHubResponseCache.Entry(etag: etag, body: data), for: key)
            }
            return data
        case 304:
            guard let cached else { throw GitHubError.unexpectedStatus(status) }
            return cached.body
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            throw Self.deniedError(status: status, response: response, body: data, rateLimit: rateLimit)
        case 404:
            throw GitHubError.notFound
        default:
            throw GitHubError.unexpectedStatus(status)
        }
    }

    /// A request that changes something. Never conditional and never cached.
    private func send(_ method: String, _ path: [String], body: Data) async throws -> Data {
        guard let url = makeURL(path, query: []) else {
            throw GitHubError.network("Could not build a request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClaudeOverhead", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Self.transportError(error)
        }
        let rateLimit = Self.rateLimit(from: response)
        if let rateLimit, Self.isCoreResource(response) { cache.record(rateLimit) }
        let message = (try? JSONDecoder().decode(MessageDTO.self, from: data))?.message
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw GitHubError.unauthorized
        case 404: throw GitHubError.notFound
        case 405, 409, 422: throw GitHubError.mergeRejected(message ?? "HTTP \(response.statusCode)")
        case 403, 429: throw Self.deniedError(status: response.statusCode, response: response, body: data, rateLimit: rateLimit)
        default: throw GitHubError.unexpectedStatus(response.statusCode)
        }
    }

    /// GitHub signals both primary and secondary rate limits with 403 or 429.
    /// Primary: `X-RateLimit-Remaining: 0` with a reset time. Secondary:
    /// `Retry-After`, or only a message mentioning the rate limit.
    private static func deniedError(
        status: Int,
        response: HTTPURLResponse,
        body: Data,
        rateLimit: GitHubRateLimit?
    ) -> GitHubError {
        let message = (try? JSONDecoder().decode(MessageDTO.self, from: body))?.message
        if rateLimit?.remaining == 0 {
            return .rateLimited(resetAt: rateLimit?.resetAt)
        }
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) {
            return .rateLimited(resetAt: Date().addingTimeInterval(retryAfter))
        }
        if status == 429 || message?.lowercased().contains("rate limit") == true {
            return .rateLimited(resetAt: nil)
        }
        return .forbidden(message)
    }

    private static func transportError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? GitHubError { return error }
        if let error = error as? URLError {
            if error.code == .cancelled { return CancellationError() }
            return GitHubError.network(error.localizedDescription)
        }
        return GitHubError.network(error.localizedDescription)
    }

    static func rateLimit(from response: HTTPURLResponse) -> GitHubRateLimit? {
        func integer(_ name: String) -> Int? {
            response.value(forHTTPHeaderField: name).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        let limit = integer("X-RateLimit-Limit")
        let remaining = integer("X-RateLimit-Remaining")
        let reset = integer("X-RateLimit-Reset").map { Date(timeIntervalSince1970: TimeInterval($0)) }
        guard limit != nil || remaining != nil || reset != nil else { return nil }
        return GitHubRateLimit(limit: limit, remaining: remaining, resetAt: reset)
    }

    private static func isCoreResource(_ response: HTTPURLResponse) -> Bool {
        guard let resource = response.value(forHTTPHeaderField: "X-RateLimit-Resource") else { return true }
        return resource.lowercased() == "core"
    }

    private func makeURL(_ path: [String], query: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/" + path.map(Self.encode).joined(separator: "/")
        components.percentEncodedQuery = query.isEmpty
            ? nil
            : query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        return components.url
    }

    /// Encodes everything outside RFC 3986's unreserved set. Branch names may
    /// contain `&`, `+`, or `#`, which the standard query encoding leaves alone.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid date \(string)")
        }
        return decoder
    }

    /// A short description naming the failing field, without echoing the body.
    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ codingPath: [any CodingKey]) -> String {
            let joined = codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return joined.isEmpty ? "top level" : joined
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \(path(context.codingPath + [key]))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "unexpected value at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context.codingPath))"
        @unknown default:
            return "invalid response"
        }
    }
}

/// ETag bodies and the latest rate limit, shared by copies of a client.
/// `@unchecked Sendable` because all state is guarded by `lock`.
final class GitHubResponseCache: @unchecked Sendable {
    struct Entry {
        let etag: String
        let body: Data
    }

    /// Entries kept. A refresh asks for at most about 16 URLs per repository
    /// once many are monitored (runs, two pull request lists, and reviews and
    /// checks for a few pull requests), so this holds a full pass over 100
    /// repositories with room to spare. It has to: a cache smaller than one
    /// pass evicts every entry before it is asked for again, no request ever
    /// comes back 304, and the hourly allowance is gone in minutes.
    static let capacity = 4_096
    /// Bytes of bodies kept. Bodies are held to answer a 304, and a long pull
    /// request list is several hundred kilobytes, so memory is bounded too.
    static let byteLimit = 96 * 1_024 * 1_024

    private struct Slot {
        var entry: Entry
        var lastUsed: UInt64
    }

    private let capacity: Int
    private let byteLimit: Int
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    private var storedBytes = 0
    private var clock: UInt64 = 0
    private var latestRateLimit: GitHubRateLimit?

    init(capacity: Int = GitHubResponseCache.capacity, byteLimit: Int = GitHubResponseCache.byteLimit) {
        self.capacity = max(1, capacity)
        self.byteLimit = max(0, byteLimit)
    }

    var count: Int {
        lock.withLock { slots.count }
    }

    func entry(for key: String) -> Entry? {
        lock.withLock {
            guard var slot = slots[key] else { return nil }
            clock += 1
            slot.lastUsed = clock
            slots[key] = slot
            return slot.entry
        }
    }

    /// Least recently used goes first. URLs asked for on every refresh stay,
    /// and the check-run URLs of commits that were since replaced, which are
    /// never asked for again, are the ones that leave.
    func store(_ entry: Entry, for key: String) {
        lock.withLock {
            if let replaced = slots.removeValue(forKey: key) {
                storedBytes -= replaced.entry.body.count
            }
            // A body larger than the whole budget is not worth emptying the cache for.
            guard entry.body.count <= byteLimit else { return }
            clock += 1
            slots[key] = Slot(entry: entry, lastUsed: clock)
            storedBytes += entry.body.count
            while slots.count > capacity || storedBytes > byteLimit,
                  let oldest = slots.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                slots[oldest.key] = nil
                storedBytes -= oldest.value.entry.body.count
            }
        }
    }

    var rateLimit: GitHubRateLimit? {
        lock.withLock { latestRateLimit }
    }

    func record(_ rateLimit: GitHubRateLimit) {
        lock.withLock { latestRateLimit = rateLimit }
    }
}

// MARK: - Review state

struct GitHubReviewRecord: Equatable, Sendable {
    let login: String
    /// GitHub's review state: APPROVED, CHANGES_REQUESTED, COMMENTED,
    /// DISMISSED, or PENDING.
    let state: String
    let submittedAt: Date?
}

extension GitHubReviewState {
    /// Mirrors how GitHub summarizes reviews. Each reviewer counts once, by
    /// their latest approving or change-requesting review; a later comment
    /// does not withdraw either, and a dismissal does. Pending (unsubmitted)
    /// reviews are private drafts and ignored. Any outstanding change request
    /// outranks approvals; with no approvals, a pending request means a review
    /// is still required.
    static func resolve(reviews: [GitHubReviewRecord], hasPendingRequests: Bool) -> GitHubReviewState {
        let chronological = reviews.enumerated().sorted { lhs, rhs in
            let left = (lhs.element.submittedAt ?? .distantPast, lhs.offset)
            let right = (rhs.element.submittedAt ?? .distantPast, rhs.offset)
            return left < right
        }
        var latest: [String: String] = [:]
        for review in chronological.map(\.element) {
            switch review.state.uppercased() {
            case "APPROVED", "CHANGES_REQUESTED":
                latest[review.login] = review.state.uppercased()
            case "DISMISSED":
                latest[review.login] = nil
            case "COMMENTED":
                if latest[review.login] == nil {
                    latest[review.login] = "COMMENTED"
                }
            default:
                continue
            }
        }
        let states = Set(latest.values)
        if states.contains("CHANGES_REQUESTED") { return .changesRequested }
        if states.contains("APPROVED") { return .approved }
        if hasPendingRequests { return .reviewRequired }
        if states.contains("COMMENTED") { return .commented }
        return .none
    }
}

// MARK: - REST payloads

private struct UserDTO: Decodable {
    let login: String?
}

private struct MessageDTO: Decodable {
    let message: String?
}

private struct MergeDTO: Decodable {
    let merged: Bool?
    let sha: String?
    let message: String?
}

private struct RepositoryDTO: Decodable {
    let id: Int64?
    let name: String?
    let fullName: String?
    let owner: UserDTO?
    let `private`: Bool?
    let defaultBranch: String?
    let archived: Bool?
    let pushedAt: Date?
    let permissions: Permissions?
    let allowMergeCommit: Bool?
    let allowSquashMerge: Bool?
    let allowRebaseMerge: Bool?

    struct Permissions: Decodable {
        let push: Bool?
    }

    var info: GitHubRepositoryInfo? {
        guard let id else { return nil }
        let parts = fullName?.split(separator: "/").map(String.init) ?? []
        guard let owner = owner?.login ?? parts.first, let name = name ?? parts.last else { return nil }
        return GitHubRepositoryInfo(
            ref: GitHubRepoRef(id: id, owner: owner, name: name, isPrivate: self.private),
            defaultBranch: defaultBranch,
            archived: archived ?? false,
            pushedAt: pushedAt,
            canPush: permissions?.push,
            mergeMethods: GitHubMergeMethod.allowed(mergeCommit: allowMergeCommit, squash: allowSquashMerge, rebase: allowRebaseMerge)
        )
    }
}

private struct TeamDTO: Decodable {
    let slug: String?
}

private struct BranchDTO: Decodable {
    let ref: String
    let sha: String?
    let repo: RepositoryDTO?
}

private struct PullRequestDTO: Decodable {
    let number: Int
    let title: String
    let htmlUrl: String
    let user: UserDTO?
    let head: BranchDTO
    let base: BranchDTO
    let draft: Bool?
    let state: String
    /// Present only on the single pull request endpoint.
    let merged: Bool?
    let mergedAt: Date?
    let updatedAt: Date?
    let requestedReviewers: [UserDTO]?
    let requestedTeams: [TeamDTO]?
    let mergeableState: String?
    let comments: Int?
    let reviewComments: Int?
    /// The rest are present only on the single pull request endpoint.
    let body: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let commits: Int?
    let createdAt: Date?
    let closedAt: Date?
    let mergeable: Bool?

    func pullRequest(fallbackRepository: String) -> GitHubPullRequest {
        let reviewers = (requestedReviewers ?? []).compactMap(\.login)
        let hasPendingRequests = !reviewers.isEmpty || !(requestedTeams ?? []).isEmpty
        return GitHubPullRequest(
            repository: base.repo?.fullName ?? fallbackRepository,
            number: number,
            title: title,
            url: htmlUrl,
            author: user?.login,
            headRef: head.ref,
            headRepository: head.repo?.fullName,
            headSha: head.sha,
            baseRef: base.ref,
            isDraft: draft ?? false,
            state: state,
            merged: merged ?? (mergedAt != nil),
            updatedAt: updatedAt,
            mergeableState: mergeableState,
            reviewState: hasPendingRequests ? .reviewRequired : .none,
            ciState: .unknown,
            commentCount: comments.map { $0 + (reviewComments ?? 0) },
            requestedReviewers: reviewers
        )
    }
}

private struct ReviewDTO: Decodable {
    let user: UserDTO?
    let state: String
    let submittedAt: Date?
}

private struct CheckRunsDTO: Decodable {
    struct CheckRun: Decodable {
        let id: Int?
        let name: String?
        let status: String?
        let conclusion: String?
        let htmlUrl: String?
    }

    let checkRuns: [CheckRun]
}

private struct WorkflowRunsDTO: Decodable {
    struct Run: Decodable {
        let id: Int
        let name: String?
        let displayTitle: String?
        let status: String?
        let conclusion: String?
        let headBranch: String?
        let headSha: String?
        let event: String?
        let createdAt: Date?
        let runStartedAt: Date?
        let updatedAt: Date?
        let htmlUrl: String
        let repository: RepositoryDTO?
        let headCommit: HeadCommit?
        let actor: UserDTO?
        let runNumber: Int?
        let runAttempt: Int?
        let workflowId: Int?

        struct HeadCommit: Decodable {
            let message: String?
        }

        func workflowRun(fallbackRepository: String) -> GitHubWorkflowRun {
            let state = CIState.from(status: status, conclusion: conclusion)
            let start = runStartedAt ?? createdAt
            var duration: TimeInterval?
            if status?.lowercased() == "completed", let start, let updatedAt, updatedAt >= start {
                duration = updatedAt.timeIntervalSince(start)
            }
            return GitHubWorkflowRun(
                id: id,
                repository: repository?.fullName ?? fallbackRepository,
                name: name ?? displayTitle ?? "Workflow",
                status: status,
                conclusion: conclusion,
                branch: headBranch,
                headSha: headSha,
                event: event,
                createdAt: createdAt,
                startedAt: runStartedAt,
                updatedAt: updatedAt,
                url: htmlUrl,
                ciState: state,
                duration: duration,
                commitMessage: headCommit?.message?
                    .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init),
                actor: actor?.login,
                runNumber: runNumber,
                runAttempt: runAttempt,
                workflowID: workflowId
            )
        }
    }

    let workflowRuns: [Run]
}

private struct JobsDTO: Decodable {
    struct Job: Decodable {
        struct Step: Decodable {
            let number: Int?
            let name: String?
            let status: String?
            let conclusion: String?
        }

        let id: Int
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
        let htmlUrl: String?
        let steps: [Step]?

        var job: GitHubWorkflowJob {
            GitHubWorkflowJob(
                id: id,
                name: name ?? "Job",
                status: status,
                conclusion: conclusion,
                startedAt: startedAt,
                completedAt: completedAt,
                url: htmlUrl,
                steps: (steps ?? []).enumerated().map { index, step in
                    GitHubJobStep(number: step.number ?? index + 1, name: step.name ?? "Step", status: step.status, conclusion: step.conclusion)
                }
            )
        }
    }

    let jobs: [Job]
}

private struct SearchDTO: Decodable {
    struct Item: Decodable {
        struct PullRequestLink: Decodable {
            let mergedAt: Date?
        }

        let number: Int
        let title: String
        let htmlUrl: String
        let user: UserDTO?
        let draft: Bool?
        let state: String
        let updatedAt: Date?
        let repositoryUrl: String?
        let comments: Int?
        /// Present only when the issue is a pull request.
        let pullRequest: PullRequestLink?

        func model() -> GitHubPullRequest? {
            guard let link = pullRequest, let repository = repositoryName else { return nil }
            return GitHubPullRequest(
                repository: repository,
                number: number,
                title: title,
                url: htmlUrl,
                author: user?.login,
                headRef: "",
                headRepository: nil,
                baseRef: "",
                isDraft: draft ?? false,
                state: state,
                merged: link.mergedAt != nil,
                updatedAt: updatedAt,
                reviewState: .reviewRequired,
                ciState: .unknown,
                commentCount: comments
            )
        }

        /// "https://api.github.com/repos/owner/name" -> "owner/name".
        private var repositoryName: String? {
            guard let repositoryUrl, let url = URL(string: repositoryUrl) else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2 else { return nil }
            return parts.suffix(2).joined(separator: "/")
        }
    }

    let items: [Item]
}

/// A repository as GitHub describes it.
public struct GitHubRepositoryInfo: Equatable, Sendable {
    public let ref: GitHubRepoRef
    public let defaultBranch: String?
    public let archived: Bool
    public let pushedAt: Date?
    /// Whether the signed-in account can push (and so merge); nil when GitHub
    /// did not say.
    public let canPush: Bool?
    public let mergeMethods: [GitHubMergeMethod]

    public init(
        ref: GitHubRepoRef,
        defaultBranch: String? = nil,
        archived: Bool = false,
        pushedAt: Date? = nil,
        canPush: Bool? = nil,
        mergeMethods: [GitHubMergeMethod] = GitHubMergeMethod.allCases
    ) {
        self.ref = ref
        self.defaultBranch = defaultBranch
        self.archived = archived
        self.pushedAt = pushedAt
        self.canPush = canPush
        self.mergeMethods = mergeMethods
    }
}
