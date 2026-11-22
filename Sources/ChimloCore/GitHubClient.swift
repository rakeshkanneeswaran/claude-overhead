import Foundation

/// Sends one request. Injected so tests never touch the network.
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

    /// A dedicated session with no URL cache or cookies: ETags are handled
    /// here, and a shared cache could answer a conditional request on our
    /// behalf, hiding the 304 the ETag cache relies on.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    public static let urlSessionTransport: GitHubTransport = { request in
        let (data, response) = try await GitHubClient.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

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
        transport: @escaping GitHubTransport = GitHubClient.urlSessionTransport
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
    public func openPullRequests(_ repo: GitRemote) async throws -> [GitHubPullRequest] {
        let pulls = try await get(
            ["repos", repo.owner, repo.name, "pulls"],
            query: [("state", "open"), ("sort", "updated"), ("direction", "desc"), ("per_page", "30")],
            as: [PullRequestDTO].self
        )
        var pullRequests = pulls.map { $0.pullRequest(fallbackRepository: repo.fullName) }
        // Sequential on purpose: GitHub's secondary rate limits penalize bursts
        // of concurrent requests from one token.
        for index in pullRequests.indices.prefix(Self.detailLimit) {
            pullRequests[index] = try await withReviewsAndChecks(pullRequests[index], in: repo)
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

    // MARK: - Details

    /// Review and check failures other than authentication and rate limiting
    /// degrade to the list's own information instead of failing the whole
    /// list; a fine-grained token without Checks access should still see PRs.
    private func withReviewsAndChecks(
        _ pullRequest: GitHubPullRequest,
        in repo: GitRemote
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
        if let records = try await reviews {
            updated.reviewState = GitHubReviewState.resolve(reviews: records, hasPendingRequests: hasPendingRequests)
        }
        if let state = try await checks {
            updated.ciState = state
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

    /// Bounds memory; oldest entries go first. A refresh touches far fewer.
    static let capacity = 256

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var latestRateLimit: GitHubRateLimit?

    func entry(for key: String) -> Entry? {
        lock.withLock { entries[key] }
    }

    func store(_ entry: Entry, for key: String) {
        lock.withLock {
            if entries.updateValue(entry, forKey: key) == nil {
                insertionOrder.append(key)
            }
            while insertionOrder.count > Self.capacity {
                entries[insertionOrder.removeFirst()] = nil
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

private struct RepositoryDTO: Decodable {
    let fullName: String?
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
        let status: String?
        let conclusion: String?
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
                duration: duration
            )
        }
    }

    let workflowRuns: [Run]
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
