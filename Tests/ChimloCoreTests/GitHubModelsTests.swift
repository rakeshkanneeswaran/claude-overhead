import Foundation
import Testing
@testable import ChimloCore

@Suite("CI state")
struct GitHubCIStateTests {
    @Test("Maps GitHub status and conclusion pairs", arguments: [
        ("queued", nil, CIState.queued),
        ("requested", nil, .queued),
        ("waiting", nil, .queued),
        ("pending", nil, .queued),
        ("in_progress", nil, .inProgress),
        ("IN_PROGRESS", nil, .inProgress),
        ("completed", "success", .success),
        ("completed", "failure", .failure),
        ("completed", "timed_out", .failure),
        ("completed", "startup_failure", .failure),
        ("completed", "action_required", .failure),
        ("completed", "cancelled", .cancelled),
        ("completed", "skipped", .skipped),
        ("completed", "neutral", .neutral),
        ("completed", "stale", .unknown),
        ("completed", nil, .unknown),
        (nil, "success", .success),
        (nil, nil, .unknown),
        ("something_new", "success", .unknown),
    ] as [(String?, String?, CIState)])
    func mapping(status: String?, conclusion: String?, expected: CIState) {
        #expect(CIState.from(status: status, conclusion: conclusion) == expected)
    }

    @Test("Combines check states, most urgent first")
    func combine() {
        #expect(CIState.combine([]) == .unknown)
        #expect(CIState.combine([.success, .failure, .inProgress]) == .failure)
        #expect(CIState.combine([.success, .queued, .inProgress]) == .inProgress)
        #expect(CIState.combine([.success, .queued]) == .queued)
        #expect(CIState.combine([.success, .cancelled]) == .cancelled)
        #expect(CIState.combine([.success, .skipped, .neutral]) == .success)
        #expect(CIState.combine([.skipped]) == .success)
        #expect(CIState.combine([.success, .unknown]) == .unknown)
    }
}

@Suite("Review state rules")
struct GitHubReviewStateTests {
    private func review(_ login: String, _ state: String, minute: Int?) -> GitHubReviewRecord {
        GitHubReviewRecord(
            login: login,
            state: state,
            submittedAt: minute.map { Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval($0 * 60)) }
        )
    }

    @Test("Each reviewer counts once, by their latest decisive review")
    func latestPerReviewer() {
        let reviews = [review("bob", "CHANGES_REQUESTED", minute: 1), review("bob", "APPROVED", minute: 2)]
        #expect(GitHubReviewState.resolve(reviews: reviews, hasPendingRequests: false) == .approved)
    }

    @Test("Submission time decides order, not array position")
    func ordersBySubmissionTime() {
        let reviews = [review("bob", "APPROVED", minute: 5), review("bob", "CHANGES_REQUESTED", minute: 1)]
        #expect(GitHubReviewState.resolve(reviews: reviews, hasPendingRequests: false) == .approved)
    }

    @Test("Any outstanding change request outranks other approvals")
    func changesRequestedWins() {
        let reviews = [review("bob", "APPROVED", minute: 1), review("carol", "CHANGES_REQUESTED", minute: 2)]
        #expect(GitHubReviewState.resolve(reviews: reviews, hasPendingRequests: false) == .changesRequested)
    }

    @Test("A later comment does not withdraw an approval")
    func commentKeepsApproval() {
        let reviews = [review("bob", "APPROVED", minute: 1), review("bob", "COMMENTED", minute: 2)]
        #expect(GitHubReviewState.resolve(reviews: reviews, hasPendingRequests: true) == .approved)
    }

    @Test("A dismissal clears that reviewer's decision")
    func dismissalClears() {
        let reviews = [review("carol", "CHANGES_REQUESTED", minute: 1), review("carol", "DISMISSED", minute: 2)]
        #expect(GitHubReviewState.resolve(reviews: reviews, hasPendingRequests: false) == .none)
        #expect(GitHubReviewState.resolve(reviews: reviews, hasPendingRequests: true) == .reviewRequired)
    }

    @Test("Pending requests without approvals mean a review is required")
    func reviewRequired() {
        let comments = [review("bob", "COMMENTED", minute: 1)]
        #expect(GitHubReviewState.resolve(reviews: [], hasPendingRequests: true) == .reviewRequired)
        #expect(GitHubReviewState.resolve(reviews: comments, hasPendingRequests: true) == .reviewRequired)
        #expect(GitHubReviewState.resolve(reviews: comments, hasPendingRequests: false) == .commented)
    }

    @Test("Unsubmitted drafts are ignored")
    func pendingIgnored() {
        let reviews = [review("bob", "PENDING", minute: nil)]
        #expect(GitHubReviewState.resolve(reviews: reviews, hasPendingRequests: false) == .none)
        #expect(GitHubReviewState.resolve(reviews: [], hasPendingRequests: false) == .none)
    }
}

@Suite("GitHub model persistence")
struct GitHubModelCodingTests {
    @Test("Pull requests and runs round-trip through JSON")
    func roundTrip() throws {
        let pullRequest = GitHubPullRequest(
            repository: "octo/app", number: 42, title: "Countdown", url: "https://github.com/octo/app/pull/42",
            author: "alice", headRef: "feature/countdown", headRepository: "octo/app", headSha: "abc",
            baseRef: "main", isDraft: false, state: "open", merged: false,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), mergeableState: "clean",
            reviewState: .approved, ciState: .success, commentCount: 3, requestedReviewers: ["carol"]
        )
        let run = GitHubWorkflowRun(
            id: 7, repository: "octo/app", name: "CI", status: "completed", conclusion: "failure",
            branch: "main", headSha: "abc", event: "push", createdAt: nil, startedAt: nil, updatedAt: nil,
            url: "https://github.com/octo/app/actions/runs/7", duration: 12
        )
        let decodedPullRequest = try JSONDecoder().decode(
            GitHubPullRequest.self,
            from: JSONEncoder().encode(pullRequest)
        )
        let decodedRun = try JSONDecoder().decode(GitHubWorkflowRun.self, from: JSONEncoder().encode(run))
        #expect(decodedPullRequest == pullRequest)
        #expect(decodedPullRequest.id == "octo/app#42")
        #expect(decodedRun == run)
        #expect(run.ciState == .failure)
    }

    @Test("Errors read as plain sentences")
    func errorDescriptions() {
        #expect(GitHubError.unauthorized.errorDescription?.contains("rejected") == true)
        #expect(GitHubError.forbidden("Resource not accessible").errorDescription?.contains("Resource not accessible") == true)
        #expect(GitHubError.rateLimited(resetAt: nil).errorDescription?.contains("rate limit") == true)
        #expect(GitHubError.unexpectedStatus(502).errorDescription?.contains("502") == true)
    }
}
