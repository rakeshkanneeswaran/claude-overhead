import Foundation
import Testing
@testable import ChimloCore

private func pullRequest(
    _ number: Int,
    repository: String = "octo/app",
    headRef: String = "feature/countdown",
    headRepository: String? = "octo/app",
    state: String = "open",
    merged: Bool = false,
    updatedMinute: Int = 0,
    reviewState: GitHubReviewState = .none,
    ciState: CIState = .unknown,
    commentCount: Int? = nil
) -> GitHubPullRequest {
    GitHubPullRequest(
        repository: repository,
        number: number,
        title: "PR \(number)",
        url: "https://github.com/\(repository)/pull/\(number)",
        author: "alice",
        headRef: headRef,
        headRepository: headRepository,
        baseRef: "main",
        isDraft: false,
        state: state,
        merged: merged,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(updatedMinute * 60)),
        reviewState: reviewState,
        ciState: ciState,
        commentCount: commentCount
    )
}

@Suite("Session to pull request matching")
struct GitHubMatchingTests {
    @Test("An exact branch from the same repository matches")
    func exactBranch() {
        let prs = [pullRequest(1, headRef: "feature/other"), pullRequest(2)]
        let match = GitHubMatching.pullRequest(forBranch: "feature/countdown", repository: "octo/app", in: prs)
        #expect(match?.number == 2)
    }

    @Test("Branch names must match exactly")
    func noPartialMatch() {
        let prs = [pullRequest(1, headRef: "feature/countdown-v2")]
        #expect(GitHubMatching.pullRequest(forBranch: "feature/countdown", repository: "octo/app", in: prs) == nil)
        #expect(GitHubMatching.pullRequest(forBranch: "feature", repository: "octo/app", in: prs) == nil)
    }

    @Test("A same-named branch from a different fork does not match")
    func forkMismatch() {
        let prs = [pullRequest(1, headRepository: "stranger/app")]
        #expect(GitHubMatching.pullRequest(forBranch: "feature/countdown", repository: "octo/app", in: prs) == nil)
        let fork = GitHubMatching.pullRequest(forBranch: "feature/countdown", repository: "stranger/app", in: prs)
        #expect(fork?.number == 1)
    }

    @Test("A deleted head repository still matches by branch")
    func nilHeadRepository() {
        let prs = [pullRequest(1, headRepository: nil)]
        #expect(GitHubMatching.pullRequest(forBranch: "feature/countdown", repository: "octo/app", in: prs)?.number == 1)
    }

    @Test("Repository names compare case-insensitively")
    func caseInsensitiveRepository() {
        let prs = [pullRequest(1, headRepository: "Octo/App")]
        #expect(GitHubMatching.pullRequest(forBranch: "feature/countdown", repository: "octo/app", in: prs)?.number == 1)
    }

    @Test("Mainline and default branches never match")
    func mainlineBranches() {
        let prs = [
            pullRequest(1, headRef: "main"),
            pullRequest(2, headRef: "master"),
            pullRequest(3, headRef: "develop"),
        ]
        #expect(GitHubMatching.pullRequest(forBranch: "main", repository: "octo/app", in: prs) == nil)
        #expect(GitHubMatching.pullRequest(forBranch: "master", repository: "octo/app", in: prs) == nil)
        #expect(GitHubMatching.pullRequest(forBranch: "develop", repository: "octo/app", in: prs)?.number == 3)
        #expect(GitHubMatching.pullRequest(
            forBranch: "develop", repository: "octo/app", in: prs, defaultBranch: "develop"
        ) == nil)
    }

    @Test("A detached HEAD matches nothing by branch")
    func detachedHead() {
        #expect(GitHubMatching.pullRequest(forBranch: nil, repository: "octo/app", in: [pullRequest(1)]) == nil)
        #expect(GitHubMatching.pullRequest(forBranch: "", repository: "octo/app", in: [pullRequest(1)]) == nil)
    }

    @Test("PR numbers linked in the transcript win, most recent first")
    func linkedNumbersWin() {
        let prs = [pullRequest(1), pullRequest(7, headRef: "other"), pullRequest(9, headRef: "another")]
        let match = GitHubMatching.pullRequest(
            forBranch: "feature/countdown", repository: "octo/app", in: prs, linkedNumbers: [7, 9]
        )
        #expect(match?.number == 9)
        let detached = GitHubMatching.pullRequest(forBranch: nil, repository: "octo/app", in: prs, linkedNumbers: [7])
        #expect(detached?.number == 7)
    }

    @Test("Linked numbers from another repository are ignored")
    func linkedNumberOtherRepository() {
        let prs = [pullRequest(1), pullRequest(7, repository: "else/where", headRef: "x", headRepository: "else/where")]
        let match = GitHubMatching.pullRequest(
            forBranch: "feature/countdown", repository: "octo/app", in: prs, linkedNumbers: [7]
        )
        #expect(match?.number == 1)
    }

    @Test("Linked numbers match a fork's PR on the parent repository")
    func linkedNumberFromFork() {
        let prs = [pullRequest(5, repository: "org/app", headRef: "fix", headRepository: "me/app")]
        let match = GitHubMatching.pullRequest(forBranch: "fix", repository: "me/app", in: prs, linkedNumbers: [5])
        #expect(match?.number == 5)
    }

    @Test("Several candidates prefer open, then most recently updated")
    func tieBreak() {
        let prs = [
            pullRequest(1, updatedMinute: 1),
            pullRequest(2, updatedMinute: 5),
            pullRequest(3, state: "closed", updatedMinute: 9),
        ]
        #expect(GitHubMatching.pullRequest(forBranch: "feature/countdown", repository: "octo/app", in: prs)?.number == 2)
    }
}

@Suite("Pull request event diff")
struct GitHubEventDiffTests {
    @Test("A pull request seen for the first time produces no events")
    func firstSnapshot() {
        let new = [pullRequest(1, reviewState: .approved, ciState: .failure, commentCount: 4)]
        #expect(GitHubEventDiff.events(from: [], to: new).isEmpty)
    }

    @Test("Unchanged snapshots produce no events")
    func unchanged() {
        let snapshot = [pullRequest(1, reviewState: .approved, ciState: .success, commentCount: 2)]
        #expect(GitHubEventDiff.events(from: snapshot, to: snapshot).isEmpty)
    }

    @Test("Review decisions produce events on transition")
    func reviewTransitions() {
        let id = "octo/app#1"
        #expect(GitHubEventDiff.events(
            from: [pullRequest(1, reviewState: .reviewRequired)],
            to: [pullRequest(1, reviewState: .changesRequested)]
        ) == [.changesRequested(prID: id)])
        #expect(GitHubEventDiff.events(
            from: [pullRequest(1, reviewState: .changesRequested)],
            to: [pullRequest(1, reviewState: .approved)]
        ) == [.approved(prID: id)])
        #expect(GitHubEventDiff.events(
            from: [pullRequest(1, reviewState: .none)],
            to: [pullRequest(1, reviewState: .commented)]
        ).isEmpty)
    }

    @Test("CI failures always surface; passes only after visible activity")
    func ciTransitions() {
        let id = "octo/app#1"
        func diff(_ old: CIState, _ new: CIState) -> [GitHubEvent] {
            GitHubEventDiff.events(from: [pullRequest(1, ciState: old)], to: [pullRequest(1, ciState: new)])
        }
        #expect(diff(.inProgress, .failure) == [.ciFailed(prID: id)])
        #expect(diff(.unknown, .failure) == [.ciFailed(prID: id)])
        #expect(diff(.failure, .failure).isEmpty)
        #expect(diff(.inProgress, .success) == [.ciPassed(prID: id)])
        #expect(diff(.failure, .success) == [.ciPassed(prID: id)])
        #expect(diff(.unknown, .success).isEmpty)
        #expect(diff(.success, .inProgress).isEmpty)
    }

    @Test("New comments report how many arrived")
    func comments() {
        let events = GitHubEventDiff.events(
            from: [pullRequest(1, commentCount: 2)],
            to: [pullRequest(1, commentCount: 5)]
        )
        #expect(events == [.newComments(prID: "octo/app#1", count: 3)])
        #expect(GitHubEventDiff.events(from: [pullRequest(1)], to: [pullRequest(1, commentCount: 5)]).isEmpty)
        #expect(GitHubEventDiff.events(
            from: [pullRequest(1, commentCount: 5)],
            to: [pullRequest(1, commentCount: 4)]
        ).isEmpty)
    }

    @Test("Merging or closing is the only event for that pull request")
    func mergedAndClosed() {
        let merged = GitHubEventDiff.events(
            from: [pullRequest(1, ciState: .inProgress)],
            to: [pullRequest(1, state: "closed", merged: true, ciState: .success, commentCount: 9)]
        )
        #expect(merged == [.merged(prID: "octo/app#1")])

        let closed = GitHubEventDiff.events(
            from: [pullRequest(2)],
            to: [pullRequest(2, state: "closed")]
        )
        #expect(closed == [.closed(prID: "octo/app#2")])
    }

    @Test("A pull request missing from the new snapshot produces nothing")
    func disappeared() {
        #expect(GitHubEventDiff.events(from: [pullRequest(1), pullRequest(2)], to: [pullRequest(2)]).isEmpty)
    }

    @Test("Events are reported per pull request in snapshot order")
    func multiplePullRequests() {
        let events = GitHubEventDiff.events(
            from: [pullRequest(1, ciState: .inProgress), pullRequest(2, reviewState: .reviewRequired)],
            to: [pullRequest(2, reviewState: .approved), pullRequest(1, ciState: .failure)]
        )
        #expect(events == [.approved(prID: "octo/app#2"), .ciFailed(prID: "octo/app#1")])
    }

    @Test("Review requests are new entries in the viewer's queue")
    func reviewRequests() {
        let before = [pullRequest(1, repository: "octo/lib")]
        let after = [pullRequest(1, repository: "octo/lib"), pullRequest(3, repository: "octo/lib")]
        #expect(GitHubEventDiff.reviewRequests(from: nil, to: after).isEmpty)
        #expect(GitHubEventDiff.reviewRequests(from: before, to: after) == [.reviewRequested(prID: "octo/lib#3")])
    }

    @Test("Dedupe keys combine kind and pull request, without counts")
    func dedupeKeys() {
        #expect(GitHubEvent.ciFailed(prID: "octo/app#12").dedupeKey == "ciFailed:octo/app#12")
        #expect(GitHubEvent.newComments(prID: "octo/app#12", count: 3).dedupeKey == "newComments:octo/app#12")
        #expect(
            GitHubEvent.newComments(prID: "octo/app#12", count: 3).dedupeKey
                == GitHubEvent.newComments(prID: "octo/app#12", count: 1).dedupeKey
        )
        #expect(GitHubEvent.merged(prID: "a/b#1").dedupeKey != GitHubEvent.closed(prID: "a/b#1").dedupeKey)
        #expect(GitHubEvent.approved(prID: "a/b#1").prID == "a/b#1")
    }
}
