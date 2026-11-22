import Foundation

/// The companion window's sidebar, in order. GitHub is one destination:
/// using GitHub and configuring it both live there, never under Settings.
public enum CompanionDestination: String, CaseIterable, Identifiable, Sendable {
    case overview, sessions, projects, agents, history, usage, github, settings

    public var id: String { rawValue }
}

/// The Settings panes, in order. There is deliberately no GitHub pane:
/// GitHub's configuration is the Integration section of the GitHub page.
public enum SettingsPaneID: String, CaseIterable, Identifiable, Sendable {
    case general, personalization, layouts, themes, sessions, notifications, agents
    case contextUsage, focus, shortcuts, privacy, advanced

    public var id: String { rawValue }
}

/// The GitHub page's own sections: one destination, several purposes.
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
    /// Sign-in, which repositories are monitored, and GitHub preferences.
    case integration

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: "Overview"
        case .repositories: "Repositories"
        case .actions: "Actions"
        case .pullRequests: "Pull Requests"
        case .reviews: "Reviews"
        case .integration: "Integration"
        }
    }

    /// Whether the section shows GitHub data, and so needs a connection.
    public var needsConnection: Bool { self != .integration }

    /// Where the page opens. Overview once GitHub is connected and watching
    /// something; until then Integration, because that is the next step.
    public static func landing(enabled: Bool, connected: Bool, monitoredRepositories: Int) -> GitHubPageTab {
        guard enabled, connected, monitoredRepositories > 0 else { return .integration }
        return .overview
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
