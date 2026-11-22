import Foundation

public enum GitHubError: Error, Equatable, Sendable, LocalizedError {
    /// The token is missing, expired, or revoked.
    case unauthorized
    /// The token works but lacks access; carries GitHub's message when given.
    case forbidden(String?)
    /// Also what GitHub returns for private repositories the token cannot see.
    case notFound
    case rateLimited(resetAt: Date?)
    case network(String)
    case decoding(String)
    case unexpectedStatus(Int)
    /// GitHub refused a merge: not mergeable (405), the head moved since it
    /// was checked (409), or the method is not allowed (422). Carries GitHub's
    /// own message.
    case mergeRejected(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "GitHub rejected the credential. Sign in again or use a new token."
        case .forbidden(let message):
            if let message, !message.isEmpty {
                "GitHub denied access: \(message)"
            } else {
                "GitHub denied access. The token may be missing a permission."
            }
        case .notFound:
            "GitHub could not find that repository, or the token cannot see it."
        case .rateLimited(let resetAt):
            if let resetAt {
                "GitHub rate limit reached. It resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "GitHub rate limit reached. Try again in a minute."
            }
        case .network(let message):
            "Could not reach GitHub: \(message)"
        case .decoding(let message):
            "GitHub sent a response Overhead could not read: \(message)"
        case .unexpectedStatus(let status):
            "GitHub returned an unexpected response (HTTP \(status))."
        case .mergeRejected(let message):
            "GitHub didn't merge it: \(message)"
        }
    }
}

/// The primary ("core") REST rate limit as of the latest response.
public struct GitHubRateLimit: Equatable, Sendable {
    public let limit: Int?
    public let remaining: Int?
    public let resetAt: Date?

    public init(limit: Int?, remaining: Int?, resetAt: Date?) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

public enum GitHubReviewState: String, Codable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
    case commented
    case none
}

/// One CI signal normalized from GitHub Actions runs and check runs.
public enum CIState: String, Codable, Sendable {
    case queued
    case inProgress
    case success
    case failure
    case cancelled
    case skipped
    case neutral
    case unknown

    /// Maps GitHub's `status` and `conclusion` pair. A conclusion only means
    /// something once the status is `completed`, but some payloads omit the
    /// status, so a conclusion alone is still honored.
    public static func from(status: String?, conclusion: String?) -> CIState {
        switch status?.lowercased() {
        case "queued", "requested", "waiting", "pending":
            return .queued
        case "in_progress":
            return .inProgress
        case "completed", nil:
            break
        default:
            return .unknown
        }
        switch conclusion?.lowercased() {
        case "success": return .success
        case "failure", "timed_out", "startup_failure", "action_required", "error": return .failure
        case "cancelled": return .cancelled
        case "skipped": return .skipped
        case "neutral": return .neutral
        default: return .unknown
        }
    }

    /// One state for a set of checks, most urgent first: a failure anywhere
    /// is a failure; anything still running means not done. Green requires
    /// every check to be success, skipped, or neutral, so an unknown check
    /// keeps the result unknown rather than claiming a pass.
    public static func combine(_ states: [CIState]) -> CIState {
        guard !states.isEmpty else { return .unknown }
        if states.contains(.failure) { return .failure }
        if states.contains(.inProgress) { return .inProgress }
        if states.contains(.queued) { return .queued }
        if states.contains(.cancelled) { return .cancelled }
        let passing: Set<CIState> = [.success, .skipped, .neutral]
        return states.allSatisfy(passing.contains) ? .success : .unknown
    }
}

public struct GitHubPullRequest: Codable, Equatable, Sendable, Identifiable {
    /// Unique across repositories, unlike `number`.
    public var id: String { "\(repository)#\(number)" }

    /// The base repository's "owner/name"; the pull request lives there.
    public let repository: String
    public let number: Int
    public let title: String
    /// The web page, for opening in a browser.
    public let url: String
    public let author: String?
    public let headRef: String
    /// "owner/name" of the branch's repository; differs from `repository`
    /// for forks and is `nil` when the fork was deleted.
    public let headRepository: String?
    /// The commit CI ran against; `nil` when GitHub did not include it.
    public let headSha: String?
    public let baseRef: String
    public let isDraft: Bool
    /// "open" or "closed"; a merged pull request is "closed" with `merged`.
    public let state: String
    public let merged: Bool
    public let updatedAt: Date?
    /// GitHub's `mergeable_state` ("clean", "dirty", "blocked", ...). Only the
    /// single pull request endpoint reports it, so list results leave it `nil`.
    public var mergeableState: String?
    public var reviewState: GitHubReviewState
    public var ciState: CIState
    /// Issue comments plus review comments from the single pull request
    /// endpoint; issue comments only from search. The list endpoint reports
    /// no counts, so its results leave it `nil`. Compare counts only between
    /// snapshots from the same endpoint.
    public var commentCount: Int?
    /// Logins of users whose review is still requested. Team requests are not
    /// listed here but still make `reviewState` `.reviewRequired`.
    public var requestedReviewers: [String]

    public init(
        repository: String,
        number: Int,
        title: String,
        url: String,
        author: String?,
        headRef: String,
        headRepository: String?,
        headSha: String? = nil,
        baseRef: String,
        isDraft: Bool,
        state: String,
        merged: Bool,
        updatedAt: Date?,
        mergeableState: String? = nil,
        reviewState: GitHubReviewState = .none,
        ciState: CIState = .unknown,
        commentCount: Int? = nil,
        requestedReviewers: [String] = []
    ) {
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.headRef = headRef
        self.headRepository = headRepository
        self.headSha = headSha
        self.baseRef = baseRef
        self.isDraft = isDraft
        self.state = state
        self.merged = merged
        self.updatedAt = updatedAt
        self.mergeableState = mergeableState
        self.reviewState = reviewState
        self.ciState = ciState
        self.commentCount = commentCount
        self.requestedReviewers = requestedReviewers
    }

    public var isOpen: Bool { state.lowercased() == "open" }
}

public struct GitHubWorkflowRun: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    /// "owner/name".
    public let repository: String
    /// The workflow's name, falling back to the run's display title.
    public let name: String
    public let status: String?
    public let conclusion: String?
    public let branch: String?
    public let headSha: String?
    public let event: String?
    public let createdAt: Date?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let url: String
    public var ciState: CIState
    /// Wall time for completed runs (last update minus start). `nil` while the
    /// run is still going, since a stored value would immediately go stale.
    public var duration: TimeInterval?
    /// The head commit's first line, when the run payload carries it.
    public var commitMessage: String?
    /// Who triggered the run.
    public var actor: String?
    /// The run's number within its workflow, as GitHub shows it ("#412").
    public var runNumber: Int?
    /// 1 for the first attempt; a re-run is a new attempt of the same run id.
    public var runAttempt: Int?
    public var workflowID: Int?

    public init(
        id: Int,
        repository: String,
        name: String,
        status: String?,
        conclusion: String?,
        branch: String?,
        headSha: String?,
        event: String?,
        createdAt: Date?,
        startedAt: Date?,
        updatedAt: Date?,
        url: String,
        ciState: CIState? = nil,
        duration: TimeInterval? = nil,
        commitMessage: String? = nil,
        actor: String? = nil,
        runNumber: Int? = nil,
        runAttempt: Int? = nil,
        workflowID: Int? = nil
    ) {
        self.commitMessage = commitMessage
        self.actor = actor
        self.runNumber = runNumber
        self.runAttempt = runAttempt
        self.workflowID = workflowID
        self.id = id
        self.repository = repository
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.branch = branch
        self.headSha = headSha
        self.event = event
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.url = url
        self.ciState = ciState ?? CIState.from(status: status, conclusion: conclusion)
        self.duration = duration
    }
}
