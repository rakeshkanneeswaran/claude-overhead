import Foundation

/// Finds the pull request a session is working on.
public enum GitHubMatching {
    /// Branches that are a repository's mainline rather than a feature branch.
    /// A session on one of these is not "working on" whatever pull request
    /// happens to come from it (release PRs from `main`, for example).
    public static let mainlineBranches: Set<String> = ["main", "master", "trunk"]

    /// - Parameters:
    ///   - branch: The session's current branch; `nil` when HEAD is detached.
    ///   - repository: "owner/name" of the session's checkout, which for a fork
    ///     is the fork, so it is compared with each PR's head repository.
    ///   - linkedNumbers: PR numbers the session itself referenced (from its
    ///     transcript), oldest first. An explicit reference beats inference,
    ///     and the most recent one wins. It applies even on a detached HEAD.
    ///   - defaultBranch: The repository's actual default branch, excluded in
    ///     addition to `mainlineBranches`.
    /// - Returns: The matching PR, preferring open over closed and then the
    ///   most recently updated when several share the branch.
    public static func pullRequest(
        forBranch branch: String?,
        repository: String,
        in prs: [GitHubPullRequest],
        linkedNumbers: [Int] = [],
        defaultBranch: String? = nil
    ) -> GitHubPullRequest? {
        for number in linkedNumbers.reversed() {
            if let linked = prs.first(where: { pr in
                pr.number == number
                    && (sameRepository(pr.repository, repository) || sameRepository(pr.headRepository, repository))
            }) {
                return linked
            }
        }

        guard let branch, !branch.isEmpty else { return nil }
        guard !mainlineBranches.contains(branch), branch != defaultBranch else { return nil }

        let candidates = prs.filter { pr in
            pr.headRef == branch
                && (pr.headRepository == nil || sameRepository(pr.headRepository, repository))
        }
        return candidates.max { lhs, rhs in
            if lhs.isOpen != rhs.isOpen { return !lhs.isOpen }
            return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
        }
    }

    /// GitHub owner and repository names are case-insensitive.
    private static func sameRepository(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

/// Something worth telling the user about a pull request.
public enum GitHubEvent: Equatable, Sendable, Hashable {
    case reviewRequested(prID: String)
    case changesRequested(prID: String)
    case approved(prID: String)
    /// `count` is how many comments arrived since the previous snapshot.
    case newComments(prID: String, count: Int)
    case ciFailed(prID: String)
    case ciPassed(prID: String)
    case merged(prID: String)
    case closed(prID: String)
    /// GitHub reports the pull request can no longer merge cleanly.
    case mergeConflict(prID: String)

    public var prID: String {
        switch self {
        case .reviewRequested(let id), .changesRequested(let id), .approved(let id),
             .newComments(let id, _), .ciFailed(let id), .ciPassed(let id),
             .merged(let id), .closed(let id), .mergeConflict(let id):
            id
        }
    }

    /// Kind plus pull request, e.g. "ciFailed:owner/repo#12". It deliberately
    /// leaves out counts, so a newer event of the same kind for the same PR
    /// replaces the older one (as a notification identifier) instead of
    /// stacking beside it.
    public var dedupeKey: String { "\(kind):\(prID)" }

    private var kind: String {
        switch self {
        case .reviewRequested: "reviewRequested"
        case .changesRequested: "changesRequested"
        case .approved: "approved"
        case .newComments: "newComments"
        case .ciFailed: "ciFailed"
        case .ciPassed: "ciPassed"
        case .merged: "merged"
        case .closed: "closed"
        case .mergeConflict: "mergeConflict"
        }
    }
}

/// Turns two snapshots of pull requests into the changes between them.
public enum GitHubEventDiff {
    /// Events for pull requests present in both snapshots, matched by `id`.
    ///
    /// Only transitions produce events: a PR seen for the first time produces
    /// none, so launching Overhead never replays old news. A PR missing from
    /// `new` also produces none; the open-PR list simply drops merged and
    /// closed PRs, so to get `.merged` or `.closed` the caller must fetch that
    /// PR (`GitHubClient.pullRequest(_:number:)`) and include it in `new`.
    /// Once a PR is merged or closed, that is its only event; its last review
    /// or CI change no longer matters.
    ///
    /// `.reviewRequested` is never produced here, because a review state of
    /// "review required" does not say whose review; use `reviewRequests`.
    public static func events(from old: [GitHubPullRequest], to new: [GitHubPullRequest]) -> [GitHubEvent] {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var events: [GitHubEvent] = []
        for current in new {
            guard let before = previous[current.id] else { continue }
            let id = current.id

            if current.merged, !before.merged {
                events.append(.merged(prID: id))
                continue
            }
            if !current.isOpen, !current.merged, before.isOpen {
                events.append(.closed(prID: id))
                continue
            }

            if current.reviewState != before.reviewState {
                switch current.reviewState {
                case .changesRequested: events.append(.changesRequested(prID: id))
                case .approved: events.append(.approved(prID: id))
                default: break
                }
            }

            if current.ciState != before.ciState {
                if current.ciState == .failure {
                    events.append(.ciFailed(prID: id))
                } else if current.ciState == .success, ciPassSources.contains(before.ciState) {
                    events.append(.ciPassed(prID: id))
                }
            }

            if current.mergeability == .conflicts, before.mergeability != .conflicts {
                events.append(.mergeConflict(prID: id))
            }

            if let count = current.commentCount, let earlier = before.commentCount, count > earlier {
                events.append(.newComments(prID: id, count: count - earlier))
            }
        }
        return events
    }

    /// A pass is news only after CI was visibly running or red. From
    /// `.unknown` it is not: that is also what a failed check lookup leaves
    /// behind, and announcing "passed" after every hiccup would be noise.
    private static let ciPassSources: Set<CIState> = [.queued, .inProgress, .failure, .cancelled]

    /// `.reviewRequested` for PRs that newly appear in the viewer's review
    /// queue (`GitHubClient.reviewRequestsForViewer()`). Pass `nil` for `old`
    /// on the first fetch, which produces no events.
    public static func reviewRequests(from old: [GitHubPullRequest]?, to new: [GitHubPullRequest]) -> [GitHubEvent] {
        guard let old else { return [] }
        let known = Set(old.map(\.id))
        return new.filter { !known.contains($0.id) }.map { .reviewRequested(prID: $0.id) }
    }
}
