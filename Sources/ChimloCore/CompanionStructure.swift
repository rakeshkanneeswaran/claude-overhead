import Foundation

/// The companion window's sidebar, in order. Settings is one destination
/// with one short list of panes; nothing is configured in two places.
public enum CompanionDestination: String, CaseIterable, Identifiable, Sendable {
    case overview, sessions, projects, agents, history, usage, github, settings

    public var id: String { rawValue }
}

/// The Settings panes, in order: one place for each kind of choice.
/// - general: Claude Code, Lock Mode, launch, display, updates, about
/// - appearance: the notch's layout and look, themes, motion
/// - notifications: sound, events (GitHub's too), quiet hours, Focus
/// - usage: context and usage thresholds
/// - github: the integration only (sign-in, repositories, what it watches);
///   using GitHub is the GitHub page
public enum SettingsPaneID: String, CaseIterable, Identifiable, Sendable {
    case general, appearance, notifications, usage, shortcuts, github, privacy

    public var id: String { rawValue }
}

/// The GitHub page's sections: what is happening on GitHub. Setting the
/// integration up is Settings → GitHub.
public enum GitHubPageTab: String, CaseIterable, Identifiable, Sendable {
    /// What needs attention.
    case overview
    /// The monitored repositories and how each is doing.
    case repositories
    /// Workflow runs.
    case actions
    case pullRequests
    /// Reviews waiting on the owner, and reviews on the owner's pull requests.
    case reviews

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: "Overview"
        case .repositories: "Repositories"
        case .actions: "Actions"
        case .pullRequests: "Pull Requests"
        case .reviews: "Reviews"
        }
    }
}

/// What the GitHub page shows before it can show GitHub data. Session
/// monitoring never depends on any of this.
public enum GitHubSetupState: Equatable, Sendable {
    /// Never set up, or turned off: explain, and offer Connect GitHub.
    case off
    /// Turned on but not signed in (or the sign-in failed or expired).
    case notConnected
    /// Signed in, but no repository chosen yet.
    case noRepositories
    case ready

    public static func from(enabled: Bool, connected: Bool, monitoredRepositories: Int) -> GitHubSetupState {
        guard enabled else { return .off }
        guard connected else { return .notConnected }
        return monitoredRepositories > 0 ? .ready : .noRepositories
    }

    /// The one button the page offers to move forward; it opens Settings → GitHub.
    public var actionTitle: String? {
        switch self {
        case .off, .notConnected: "Connect GitHub"
        case .noRepositories: "Choose repositories"
        case .ready: nil
        }
    }
}

/// What another surface (the notch, a shortcut) asks the GitHub page to show.
public enum GitHubPageRequest: Equatable, Sendable {
    case tab(GitHubPageTab)
    case detail(GitHubDetail)

    /// The section the request lands on.
    public var tab: GitHubPageTab {
        switch self {
        case let .tab(tab): tab
        case let .detail(detail):
            switch detail {
            case .run: .actions
            case .pullRequest: .pullRequests
            case .repositories: .repositories
            }
        }
    }
}
