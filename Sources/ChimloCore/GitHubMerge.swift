import Foundation

/// How GitHub combines a pull request into its base branch.
public enum GitHubMergeMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case merge
    case squash
    case rebase

    public var id: String { rawValue }

    /// GitHub's own button wording, so nothing reads differently from github.com.
    public var displayName: String {
        switch self {
        case .merge: "Create a merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }

    public var shortName: String {
        switch self {
        case .merge: "Merge"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }

    /// The methods a repository allows. GitHub only reports these flags to
    /// people who can push; when a flag is missing the method is offered and
    /// GitHub has the final word.
    public static func allowed(mergeCommit: Bool?, squash: Bool?, rebase: Bool?) -> [GitHubMergeMethod] {
        var methods: [GitHubMergeMethod] = []
        if mergeCommit != false { methods.append(.merge) }
        if squash != false { methods.append(.squash) }
        if rebase != false { methods.append(.rebase) }
        return methods
    }

    /// The owner's last choice in this repository when still allowed, else the
    /// first allowed method in GitHub's own order.
    public static func preferred(among allowed: [GitHubMergeMethod], last: GitHubMergeMethod?) -> GitHubMergeMethod? {
        if let last, allowed.contains(last) { return last }
        return allowed.first
    }
}

/// Whether a pull request can be merged right now, and if not, why. Only
/// GitHub's own answer counts: Overhead never guesses a pull request is safe.
public enum GitHubMergeEligibility: Equatable, Sendable {
    case eligible
    case notOpen
    case draft
    case conflicts
    /// Required reviews or required checks are not satisfied.
    case blocked
    /// Branch protection wants the branch brought up to date first.
    case behind
    /// Mergeable, but some checks are failing or still running.
    case checksNotPassing
    /// GitHub has not finished working out whether it can merge.
    case unknown
    /// The signed-in account cannot push to this repository.
    case noPermission

    public var isEligible: Bool { self == .eligible }

    public var reason: String? {
        switch self {
        case .eligible: nil
        case .notOpen: "This pull request is closed."
        case .draft: "Drafts can't be merged. Mark it ready for review on GitHub first."
        case .conflicts: "It has merge conflicts with the base branch."
        case .blocked: "Required reviews or checks aren't satisfied yet."
        case .behind: "The branch must be brought up to date with the base branch first."
        case .checksNotPassing: "Some checks are failing or still running."
        case .unknown: "GitHub is still working out whether it can merge."
        case .noPermission: "Your GitHub account can't merge in this repository."
        }
    }

    /// Decides from the single-pull-request response, which is the only one
    /// that carries `mergeable` and `mergeable_state`. Eligible means GitHub
    /// says everything required has passed ("clean", or "has_hooks" on
    /// GitHub Enterprise), the pull request is open and ready, and nothing
    /// says the account lacks push access.
    public static func evaluate(
        _ pullRequest: GitHubPullRequest,
        mergeable: Bool?,
        canPush: Bool?
    ) -> GitHubMergeEligibility {
        guard pullRequest.isOpen, !pullRequest.merged else { return .notOpen }
        if pullRequest.isDraft { return .draft }
        if canPush == false { return .noPermission }
        if mergeable == false { return .conflicts }
        switch pullRequest.mergeability {
        case .ready: return mergeable == true ? .eligible : .unknown
        case .conflicts: return .conflicts
        case .blocked: return .blocked
        case .behind: return .behind
        case .unstable: return .checksNotPassing
        case .draft: return .draft
        case .unknown: return .unknown
        }
    }
}

/// What GitHub said after a merge request.
public struct GitHubMergeResult: Equatable, Sendable {
    public let merged: Bool
    /// The commit the merge produced on the base branch.
    public let sha: String?
    public let message: String?

    public init(merged: Bool, sha: String?, message: String?) {
        self.merged = merged
        self.sha = sha
        self.message = message
    }
}
