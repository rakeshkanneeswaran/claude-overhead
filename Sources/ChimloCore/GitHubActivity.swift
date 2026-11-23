import Foundation

// MARK: - Workflow runs and jobs

/// A workflow run's state as people read it, from GitHub's status and
/// conclusion pair. Unlike `CIState` it keeps "waiting" (a deployment or an
/// approval gate) apart from "queued", because the two need different action.
public enum GitHubRunStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case waiting
    case inProgress
    case success
    case failure
    case cancelled
    case skipped
    case neutral
    case unknown

    public static func from(status: String?, conclusion: String?) -> GitHubRunStatus {
        switch status?.lowercased() {
        case "queued", "requested", "pending": return .queued
        case "waiting": return .waiting
        case "in_progress": return .inProgress
        case "completed", nil: break
        default: return .unknown
        }
        switch conclusion?.lowercased() {
        case "success": return .success
        case "failure", "timed_out", "startup_failure": return .failure
        case "cancelled": return .cancelled
        case "skipped": return .skipped
        case "neutral", "stale": return .neutral
        // A run that needs someone to approve it is waiting on a person.
        case "action_required": return .waiting
        default: return .unknown
        }
    }

    /// Still going: queued, waiting or running.
    public var isActive: Bool { self == .queued || self == .waiting || self == .inProgress }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .waiting: "Waiting"
        case .inProgress: "In progress"
        case .success: "Succeeded"
        case .failure: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .neutral: "Neutral"
        case .unknown: "Unknown"
        }
    }
}

extension GitHubWorkflowRun {
    public var runStatus: GitHubRunStatus { .from(status: status, conclusion: conclusion) }

    /// Time since the run started, only while it is still going and only when
    /// GitHub said when it started. Never estimated.
    public func elapsed(at now: Date) -> TimeInterval? {
        guard runStatus.isActive, let start = startedAt ?? createdAt, now >= start else { return nil }
        return now.timeIntervalSince(start)
    }

    public var shortSha: String? {
        guard let headSha, headSha.count >= 7 else { return headSha }
        return String(headSha.prefix(7))
    }

    /// Key for "the same workflow on the same branch", to compare runs over time.
    var workflowKey: String { "\(repository)|\(workflowID.map(String.init) ?? name)|\(branch ?? "")" }
}

public struct GitHubJobStep: Codable, Equatable, Sendable {
    public let number: Int
    public let name: String
    public let status: String?
    public let conclusion: String?

    public init(number: Int, name: String, status: String?, conclusion: String?) {
        self.number = number
        self.name = name
        self.status = status
        self.conclusion = conclusion
    }

    public var runStatus: GitHubRunStatus { .from(status: status, conclusion: conclusion) }
}

/// One job of a workflow run, fetched only when the owner opens the run.
public struct GitHubWorkflowJob: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let status: String?
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?
    /// The job's page on github.com, which is also where its log lives.
    public let url: String?
    public let steps: [GitHubJobStep]

    public init(
        id: Int,
        name: String,
        status: String?,
        conclusion: String?,
        startedAt: Date?,
        completedAt: Date?,
        url: String?,
        steps: [GitHubJobStep]
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.url = url
        self.steps = steps
    }

    public var runStatus: GitHubRunStatus { .from(status: status, conclusion: conclusion) }

    public var duration: TimeInterval? {
        guard let startedAt, let completedAt, completedAt >= startedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }

    /// The steps that failed, in order; what to read first in a red job.
    public var failedSteps: [GitHubJobStep] { steps.filter { $0.runStatus == .failure } }
}

// MARK: - Pull request detail

public struct GitHubReview: Codable, Equatable, Sendable {
    public let author: String
    /// GitHub's state: APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED.
    public let state: String
    public let submittedAt: Date?

    public init(author: String, state: String, submittedAt: Date?) {
        self.author = author
        self.state = state
        self.submittedAt = submittedAt
    }

    public var label: String {
        switch state.uppercased() {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Requested changes"
        case "COMMENTED": "Commented"
        case "DISMISSED": "Dismissed"
        default: state.capitalized
        }
    }
}

public struct GitHubCheckRun: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let status: String?
    public let conclusion: String?
    public let url: String?

    public init(id: Int, name: String, status: String?, conclusion: String?, url: String?) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.url = url
    }

    public var runStatus: GitHubRunStatus { .from(status: status, conclusion: conclusion) }
}

/// Everything about one pull request that the list leaves out, fetched only
/// when the owner opens it.
public struct GitHubPullRequestDetail: Equatable, Sendable {
    public var pullRequest: GitHubPullRequest
    public var body: String?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var commits: Int?
    public var createdAt: Date?
    public var mergedAt: Date?
    public var closedAt: Date?
    /// Newest first.
    public var reviews: [GitHubReview]
    public var checks: [GitHubCheckRun]
    /// GitHub's `mergeable`: false means conflicts, nil means not computed yet.
    public var mergeable: Bool?

    public init(
        pullRequest: GitHubPullRequest,
        body: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        changedFiles: Int? = nil,
        commits: Int? = nil,
        createdAt: Date? = nil,
        mergedAt: Date? = nil,
        closedAt: Date? = nil,
        reviews: [GitHubReview] = [],
        checks: [GitHubCheckRun] = [],
        mergeable: Bool? = nil
    ) {
        self.mergeable = mergeable
        self.pullRequest = pullRequest
        self.body = body
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.commits = commits
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.reviews = reviews
        self.checks = checks
    }

    /// The description trimmed for a small panel. The full text stays on
    /// GitHub; nothing here is shortened silently.
    public func bodyPreview(limit: Int = 600) -> (text: String, truncated: Bool)? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        guard body.count > limit else { return (body, false) }
        return (String(body.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…", true)
    }
}

// MARK: - Mergeability and filters

/// What GitHub's `mergeable_state` says, when GitHub has computed it.
public enum GitHubMergeability: String, Sendable {
    case ready
    case conflicts
    case blocked
    case behind
    case unstable
    case draft
    case unknown

    public static func from(_ state: String?) -> GitHubMergeability {
        switch state?.lowercased() {
        case "clean", "has_hooks": .ready
        case "dirty": .conflicts
        case "blocked": .blocked
        case "behind": .behind
        case "unstable": .unstable
        case "draft": .draft
        default: .unknown
        }
    }

    public var label: String? {
        switch self {
        case .ready: "Mergeable"
        case .conflicts: "Merge conflicts"
        case .blocked: "Merge blocked"
        case .behind: "Behind base branch"
        case .unstable: "Mergeable, checks not passing"
        case .draft: "Draft"
        case .unknown: nil
        }
    }
}

extension GitHubPullRequest {
    public var mergeability: GitHubMergeability { .from(mergeableState) }

    /// Approved, checks green, not a draft, and GitHub has not reported a
    /// conflict or a block. Unknown merge state does not disqualify: GitHub
    /// computes it lazily and the list endpoint never includes it.
    public var isReadyToMerge: Bool {
        guard isOpen, !isDraft, reviewState == .approved, ciState == .success else { return false }
        let mergeability = mergeability
        return mergeability != .conflicts && mergeability != .blocked && mergeability != .draft
    }
}

// MARK: - Detail carried between refreshes

/// Reviews and checks are looked up only for the most recently updated pull
/// requests, and a lookup can fail. A pull request that got no answer this
/// time keeps what was last known for the same head commit, instead of
/// dropping to "unknown" and then looking like a fresh failure or approval
/// when its turn comes round again.
extension GitHubPullRequest {
    /// The same pull request at the same commit, so earlier detail still
    /// describes it. A pull request without a head commit never matches.
    func hasSameHead(as earlier: GitHubPullRequest) -> Bool {
        guard id == earlier.id, let headSha, !headSha.isEmpty else { return false }
        return headSha == earlier.headSha
    }

    /// For a pass that made no review lookup. An approval or a change
    /// request stands until a lookup says otherwise; a pending request is
    /// something the list itself reports, so the list's word wins there.
    func carryingReviewState(from earlier: GitHubPullRequest) -> GitHubPullRequest {
        guard hasSameHead(as: earlier) else { return self }
        var copy = self
        switch earlier.reviewState {
        case .changesRequested, .approved:
            copy.reviewState = earlier.reviewState
        case .commented:
            if reviewState == .none { copy.reviewState = .commented }
        case .reviewRequired, .none:
            break
        }
        return copy
    }

    /// For a pass that made no check lookup, which leaves `.unknown`.
    func carryingCIState(from earlier: GitHubPullRequest) -> GitHubPullRequest {
        guard ciState == .unknown, hasSameHead(as: earlier) else { return self }
        var copy = self
        copy.ciState = earlier.ciState
        return copy
    }

    /// Keeps GitHub's last merge verdict while this pass has none: the list
    /// never reports one, the single pull request lookup can fail, and
    /// GitHub answers "unknown" while it recomputes. Without this a conflict
    /// would clear and then be announced again.
    public func carryingMergeState(from earlier: GitHubPullRequest) -> GitHubPullRequest {
        let undecided = mergeableState == nil || mergeableState?.lowercased() == "unknown"
        guard undecided, earlier.mergeableState != nil, hasSameHead(as: earlier) else { return self }
        var copy = self
        copy.mergeableState = earlier.mergeableState
        return copy
    }

    /// `carryingMergeState` for a whole list, matched by pull request.
    public static func carryingMergeStates(
        _ current: [GitHubPullRequest],
        from earlier: [GitHubPullRequest]
    ) -> [GitHubPullRequest] {
        guard !earlier.isEmpty else { return current }
        let known = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.map { pullRequest in
            known[pullRequest.id].map(pullRequest.carryingMergeState(from:)) ?? pullRequest
        }
    }
}

public enum GitHubPRFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case all
    case open
    case draft
    case reviewRequested
    case changesRequested
    case approved
    case ciFailing
    case readyToMerge
    case merged

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .open: "Open"
        case .draft: "Draft"
        case .reviewRequested: "Review requested"
        case .changesRequested: "Changes requested"
        case .approved: "Approved"
        case .ciFailing: "CI failing"
        case .readyToMerge: "Ready to merge"
        case .merged: "Merged"
        }
    }

    public func matches(_ pr: GitHubPullRequest) -> Bool {
        switch self {
        case .all: true
        case .open: pr.isOpen && !pr.isDraft
        case .draft: pr.isOpen && pr.isDraft
        case .reviewRequested: pr.isOpen && pr.reviewState == .reviewRequired
        case .changesRequested: pr.isOpen && pr.reviewState == .changesRequested
        case .approved: pr.isOpen && pr.reviewState == .approved
        case .ciFailing: pr.isOpen && pr.ciState == .failure
        case .readyToMerge: pr.isReadyToMerge
        case .merged: pr.merged
        }
    }

    public func apply(_ pullRequests: [GitHubPullRequest]) -> [GitHubPullRequest] {
        pullRequests.filter(matches)
    }
}

// MARK: - Snapshot, overview and the notch indicator

/// What Overhead knows about one monitored repository right now.
public struct GitHubRepoSnapshot: Equatable, Sendable, Identifiable {
    public var id: Int64 { ref.id }
    public var ref: GitHubRepoRef
    public var availability: GitHubRepoAvailability
    /// Open pull requests, most recently updated first.
    public var pullRequests: [GitHubPullRequest]
    /// Recently merged or closed pull requests, newest first.
    public var recentlyClosed: [GitHubPullRequest]
    /// Recent workflow runs, newest first.
    public var runs: [GitHubWorkflowRun]
    public var defaultBranch: String?
    public var lastUpdated: Date?

    public init(
        ref: GitHubRepoRef,
        availability: GitHubRepoAvailability = .unknown,
        pullRequests: [GitHubPullRequest] = [],
        recentlyClosed: [GitHubPullRequest] = [],
        runs: [GitHubWorkflowRun] = [],
        defaultBranch: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.ref = ref
        self.availability = availability
        self.pullRequests = pullRequests
        self.recentlyClosed = recentlyClosed
        self.runs = runs
        self.defaultBranch = defaultBranch
        self.lastUpdated = lastUpdated
    }

    /// Open first, then recently closed; what the PR filters work over.
    public var allPullRequests: [GitHubPullRequest] { pullRequests + recentlyClosed }

    /// The newest run of each workflow and branch. A workflow that failed and
    /// then passed is no longer failing, so counts use this, not every run.
    public var latestRunPerWorkflow: [GitHubWorkflowRun] {
        var seen = Set<String>()
        return runs.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .filter { seen.insert($0.workflowKey).inserted }
    }

    public var activeRuns: [GitHubWorkflowRun] { runs.filter { $0.runStatus.isActive } }
    public var failingRuns: [GitHubWorkflowRun] { latestRunPerWorkflow.filter { $0.runStatus == .failure } }

    /// The newest moment anything here changed.
    public var latestActivity: Date? {
        (runs.compactMap { $0.updatedAt ?? $0.createdAt } + allPullRequests.compactMap(\.updatedAt)).max()
    }
}

/// One thing in GitHub that wants the owner's attention, most urgent first.
public enum GitHubAttention: Equatable, Sendable {
    case failedRun(GitHubWorkflowRun)
    case mergeConflict(GitHubPullRequest)
    case changesRequested(GitHubPullRequest)
    case ciFailing(GitHubPullRequest)
    case reviewRequested(GitHubPullRequest)

    public var isFailedRun: Bool {
        if case .failedRun = self { return true }
        return false
    }

    var rank: Int {
        switch self {
        case .failedRun: 0
        case .mergeConflict: 1
        case .changesRequested: 2
        case .ciFailing: 3
        case .reviewRequested: 4
        }
    }
}

/// The numbers and the short list GitHub Mode opens on.
public struct GitHubOverview: Equatable, Sendable {
    public var openPullRequests: Int
    public var runningRuns: Int
    public var failedWorkflows: Int
    /// Pull requests waiting on the viewer's review.
    public var reviewsWaiting: Int
    public var attention: [GitHubAttention]
    public var latestActivity: Date?
    public var unavailableRepositories: Int

    public static let empty = GitHubOverview(
        openPullRequests: 0, runningRuns: 0, failedWorkflows: 0, reviewsWaiting: 0,
        attention: [], latestActivity: nil, unavailableRepositories: 0
    )

    public init(
        openPullRequests: Int, runningRuns: Int, failedWorkflows: Int, reviewsWaiting: Int,
        attention: [GitHubAttention], latestActivity: Date?, unavailableRepositories: Int
    ) {
        self.openPullRequests = openPullRequests
        self.runningRuns = runningRuns
        self.failedWorkflows = failedWorkflows
        self.reviewsWaiting = reviewsWaiting
        self.attention = attention
        self.latestActivity = latestActivity
        self.unavailableRepositories = unavailableRepositories
    }

    /// Builds the overview for some repositories. `reviewRequests` are the
    /// viewer's review queue across GitHub; only those in these repositories
    /// count. Changes requested and conflicts count only on the viewer's own
    /// pull requests, since those are the ones the viewer has to act on.
    public static func make(
        _ repositories: [GitHubRepoSnapshot],
        reviewRequests: [GitHubPullRequest],
        viewer: String?
    ) -> GitHubOverview {
        let names = Set(repositories.map { $0.ref.fullName.lowercased() })
        let waiting = reviewRequests.filter { names.contains($0.repository.lowercased()) }
        let viewerKey = viewer?.lowercased()
        func isViewers(_ pr: GitHubPullRequest) -> Bool {
            guard let viewerKey, let author = pr.author?.lowercased() else { return false }
            return author == viewerKey
        }
        var attention: [GitHubAttention] = []
        for repository in repositories {
            attention += repository.failingRuns.map(GitHubAttention.failedRun)
            for pr in repository.pullRequests where pr.isOpen {
                if isViewers(pr), pr.mergeability == .conflicts {
                    attention.append(.mergeConflict(pr))
                } else if isViewers(pr), pr.reviewState == .changesRequested {
                    attention.append(.changesRequested(pr))
                } else if isViewers(pr), pr.ciState == .failure {
                    attention.append(.ciFailing(pr))
                }
            }
        }
        attention += waiting.map(GitHubAttention.reviewRequested)
        attention.sort { $0.rank < $1.rank }
        return GitHubOverview(
            openPullRequests: repositories.reduce(0) { $0 + $1.pullRequests.filter(\.isOpen).count },
            runningRuns: repositories.reduce(0) { $0 + $1.activeRuns.count },
            failedWorkflows: repositories.reduce(0) { $0 + $1.failingRuns.count },
            reviewsWaiting: waiting.count,
            attention: attention,
            latestActivity: repositories.compactMap(\.latestActivity).max(),
            unavailableRepositories: repositories.filter { $0.availability.isUnavailable }.count
        )
    }
}

/// What the GitHub button (and the closed notch) shows. Ordered by urgency;
/// only the most urgent state shows.
public enum GitHubIndicator: Equatable, Sendable {
    /// GitHub is off, signed out, or failing to connect.
    case unavailable
    case idle
    /// Something changed since the owner last opened GitHub Mode.
    case activity
    case running
    /// A review waits on the owner, or their PR has requested changes or a conflict.
    case attention
    case failed

    /// Failed and attention come only from outstanding alerts: one the owner
    /// dismissed no longer raises the badge, though the data behind it (the
    /// overview's counts, the run, the pull request) stays as GitHub reports.
    public static func resolve(
        enabled: Bool,
        connected: Bool,
        overview: GitHubOverview,
        lastViewed: Date?,
        showRunning: Bool,
        showPullRequests: Bool,
        dismissals: GitHubAlertDismissals = GitHubAlertDismissals()
    ) -> GitHubIndicator {
        guard enabled, connected else { return .unavailable }
        let outstanding = dismissals.outstanding(overview.attention)
        if outstanding.contains(where: \.isFailedRun) { return .failed }
        if showPullRequests, outstanding.contains(where: { !$0.isFailedRun }) {
            return .attention
        }
        if showRunning, overview.runningRuns > 0 { return .running }
        if let latest = overview.latestActivity, latest > (lastViewed ?? .distantPast) { return .activity }
        return .idle
    }

    /// Whether the closed notch should carry this state. The closed notch is
    /// for things that need the owner, never for routine activity.
    public var showsInClosedNotch: Bool { self == .failed || self == .attention }
}

// MARK: - Run events

/// A workflow run worth telling the owner about.
public enum GitHubRunEvent: Equatable, Sendable {
    case started(GitHubWorkflowRun)
    case failed(GitHubWorkflowRun)
    case succeeded(GitHubWorkflowRun)

    public var run: GitHubWorkflowRun {
        switch self {
        case let .started(run), let .failed(run), let .succeeded(run): run
        }
    }

    public var kind: OverheadEventKind {
        switch self {
        case .started: .githubWorkflowStarted
        case .failed: .githubWorkflowFailed
        case .succeeded: .githubWorkflowSucceeded
        }
    }

    /// Per run attempt, so a re-run that fails again is news again.
    public var dedupeKey: String { "run:\(run.repository)#\(run.id).\(run.runAttempt ?? 1)" }
}

public enum GitHubRunEventDiff {
    /// Transitions between two snapshots of a repository's runs. `old == nil`
    /// is the first look, which never produces events: launching Overhead does
    /// not replay old results. A run first seen already finished (it started
    /// and ended between two polls) still reports its result.
    public static func events(from old: [GitHubWorkflowRun]?, to new: [GitHubWorkflowRun]) -> [GitHubRunEvent] {
        guard let old else { return [] }
        let previous = Dictionary(old.map { ("\($0.id).\($0.runAttempt ?? 1)", $0) }, uniquingKeysWith: { _, latest in latest })
        let oldestSeen = old.compactMap(\.createdAt).min()
        var events: [GitHubRunEvent] = []
        for run in new {
            let status = run.runStatus
            if let before = previous["\(run.id).\(run.runAttempt ?? 1)"] {
                guard before.runStatus.isActive, !status.isActive else { continue }
                if let event = finished(run, status) { events.append(event) }
            } else {
                // Older than anything in the previous snapshot: it scrolled
                // into view, it did not just happen.
                if let oldestSeen, let created = run.createdAt, created < oldestSeen { continue }
                if status.isActive {
                    events.append(.started(run))
                } else if let event = finished(run, status) {
                    events.append(event)
                }
            }
        }
        return events
    }

    private static func finished(_ run: GitHubWorkflowRun, _ status: GitHubRunStatus) -> GitHubRunEvent? {
        switch status {
        case .failure: .failed(run)
        case .success: .succeeded(run)
        default: nil
        }
    }
}

// MARK: - Notifications: per-repository level and grouping

/// How much one repository may notify.
public enum GitHubAlertLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Every GitHub event the notification settings allow.
    case all
    /// Only failures, conflicts, requested changes and review requests.
    case important
    /// Nothing; the repository is still shown in GitHub Mode.
    case off

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All activity"
        case .important: "Failures and reviews"
        case .off: "Off"
        }
    }

    public func allows(_ kind: OverheadEventKind) -> Bool {
        switch self {
        case .all: true
        case .important: kind.priority == .critical || kind == .githubReviewRequested
        case .off: false
        }
    }
}

/// A GitHub notice on its way to the notification policy.
public struct GitHubNotice: Equatable, Sendable {
    public var kind: OverheadEventKind
    public var key: String
    public var repository: String
    public var title: String
    public var body: String

    public init(kind: OverheadEventKind, key: String, repository: String, title: String, body: String) {
        self.kind = kind
        self.key = key
        self.repository = repository
        self.title = title
        self.body = body
    }
}

public enum GitHubNoticeGrouping {
    /// Several notices of one kind from one repository in the same refresh
    /// become one ("3 workflows failed"), so a push that breaks five workflows
    /// interrupts once. The group's key joins its members' keys, so the same
    /// group is still recognized as a duplicate.
    public static func group(_ notices: [GitHubNotice], enabled: Bool) -> [GitHubNotice] {
        guard enabled else { return notices }
        var order: [String] = []
        var buckets: [String: [GitHubNotice]] = [:]
        for notice in notices {
            let bucket = "\(notice.kind.rawValue)|\(notice.repository.lowercased())"
            if buckets[bucket] == nil { order.append(bucket) }
            buckets[bucket, default: []].append(notice)
        }
        return order.compactMap { bucket in
            guard let members = buckets[bucket], let first = members.first else { return nil }
            guard members.count > 1 else { return first }
            return GitHubNotice(
                kind: first.kind,
                key: members.map(\.key).sorted().joined(separator: ","),
                repository: first.repository,
                title: first.repository,
                body: summary(first.kind, count: members.count)
            )
        }
    }

    static func summary(_ kind: OverheadEventKind, count: Int) -> String {
        switch kind {
        case .githubWorkflowFailed: "\(count) workflows failed."
        case .githubWorkflowSucceeded: "\(count) workflows succeeded."
        case .githubWorkflowStarted: "\(count) workflows started."
        case .githubCIFailed: "Checks failed on \(count) pull requests."
        case .githubCIPassed: "Checks passed on \(count) pull requests."
        case .githubReviewRequested: "Your review was requested on \(count) pull requests."
        case .githubChangesRequested: "Changes were requested on \(count) pull requests."
        case .githubApproved: "\(count) pull requests were approved."
        case .githubMerged: "\(count) pull requests were merged."
        case .githubMergeConflict: "\(count) pull requests have merge conflicts."
        case .githubNewComments: "New comments on \(count) pull requests."
        default: "\(count) updates."
        }
    }
}

// MARK: - Polling budget

public enum GitHubPollBudget {
    /// Review and check lookups each pull request costs two requests, so the
    /// per-repository allowance shrinks as more repositories are monitored
    /// (about 40 lookups a refresh in total) and stops when GitHub says the
    /// hourly allowance is nearly spent. Conditional requests that come back
    /// 304 are free, which is why this budget is generous rather than strict.
    public static func detailLimit(repositoryCount: Int, remaining: Int?) -> Int {
        if let remaining, remaining < 300 { return 0 }
        guard repositoryCount > 0 else { return GitHubClient.detailLimit }
        return min(GitHubClient.detailLimit, max(2, 40 / repositoryCount))
    }

    /// How soon to look again at repositories with running workflows, when
    /// the owner allows faster checks. Never faster than 45 seconds.
    public static let activeRunInterval: TimeInterval = 45
}

// MARK: - Lookups that failed

/// Remembers lookups that failed, so they are not repeated on every refresh.
/// A folder that is not a repository, or a repository this sign-in cannot
/// see, is asked about again only after `interval`: often enough to notice a
/// `git init` or a new permission, without spending a request (or a git
/// process) on it every 30 seconds.
public struct GitHubLookupBackoff: Sendable {
    public let interval: TimeInterval
    private var failures: [String: Date] = [:]

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Whether `key` failed recently enough to leave alone for now.
    public func shouldSkip(_ key: String, at now: Date = .now) -> Bool {
        guard let failedAt = failures[key] else { return false }
        let elapsed = now.timeIntervalSince(failedAt)
        // A clock set back makes the failure look like the future; ask again.
        return elapsed >= 0 && elapsed < interval
    }

    public mutating func recordFailure(_ key: String, at now: Date = .now) {
        // Lapsed entries go here, so the record never outgrows what is live.
        failures = failures.filter { now.timeIntervalSince($0.value) < interval }
        failures[key] = now
    }

    public mutating func recordSuccess(_ key: String) {
        failures[key] = nil
    }

    /// Forgets everything, for a new sign-in that may see what the last one could not.
    public mutating func reset() {
        failures.removeAll()
    }
}
