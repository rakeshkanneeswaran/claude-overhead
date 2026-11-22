import Foundation

/// What the open notch is showing.
public enum NotchContent: String, Codable, Sendable {
    /// Claude sessions, questions and permissions. The default.
    case claude
    /// Repositories, workflow runs and pull requests.
    case github
}

/// The three GitHub Mode tabs.
public enum GitHubView: String, Codable, Sendable, CaseIterable, Identifiable {
    case overview
    case actions
    case pullRequests

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: "Overview"
        case .actions: "Actions"
        case .pullRequests: "Pull requests"
        }
    }
}

/// Where GitHub Mode opens.
public enum GitHubDefaultView: String, Codable, Sendable, CaseIterable, Identifiable {
    case overview
    case actions
    case pullRequests
    /// The tab, repository and detail the owner had open last time.
    case lastActive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview: "Overview"
        case .actions: "Actions"
        case .pullRequests: "Pull requests"
        case .lastActive: "Where I left off"
        }
    }
}

/// Something opened on top of a tab.
public enum GitHubDetail: Equatable, Hashable, Sendable {
    case run(repositoryID: Int64, runID: Int)
    case pullRequest(repositoryID: Int64, number: Int)
    /// The quick repository switcher.
    case repositories
}

public enum GitHubPanelDensity: String, Codable, Sendable, CaseIterable, Identifiable {
    case compact
    case expanded

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: "Compact"
        case .expanded: "Expanded"
        }
    }

    /// Rows per list before "show more" in the notch.
    public var rowLimit: Int { self == .compact ? 4 : 8 }

    /// Height of the GitHub panel below the notch's status band, in points.
    /// Fixed per density so switching tabs never makes the notch jump; long
    /// content scrolls inside it.
    public var contentHeight: Double { self == .compact ? 292 : 404 }
}

/// GitHub Mode's navigation, kept apart from Claude's state so switching
/// modes never disturbs either one.
///
/// Claude Mode wins whenever Claude is blocked on the owner: a permission
/// request or question always shows, even if the owner was in GitHub Mode.
/// GitHub Mode's place is kept, so once the request is answered the owner is
/// back where they were.
public struct GitHubNavigation: Equatable, Sendable {
    public private(set) var content: NotchContent
    public private(set) var view: GitHubView
    public private(set) var detail: GitHubDetail?
    public var pullRequestFilter: GitHubPRFilter

    public init(
        content: NotchContent = .claude,
        view: GitHubView = .overview,
        detail: GitHubDetail? = nil,
        pullRequestFilter: GitHubPRFilter = .open
    ) {
        self.content = content
        self.view = view
        self.detail = detail
        self.pullRequestFilter = pullRequestFilter
    }

    /// Enters GitHub Mode at the owner's chosen view. "Where I left off"
    /// keeps the tab and detail; any other choice starts on that tab.
    public mutating func openGitHub(defaultView: GitHubDefaultView) {
        content = .github
        switch defaultView {
        case .overview: view = .overview; detail = nil
        case .actions: view = .actions; detail = nil
        case .pullRequests: view = .pullRequests; detail = nil
        case .lastActive: break
        }
    }

    /// Back to Claude. GitHub's tab and detail are kept for next time.
    public mutating func returnToClaude() {
        content = .claude
    }

    public mutating func toggle(defaultView: GitHubDefaultView) {
        if content == .github { returnToClaude() } else { openGitHub(defaultView: defaultView) }
    }

    public mutating func show(_ view: GitHubView) {
        self.view = view
        detail = nil
    }

    public mutating func open(_ detail: GitHubDetail) {
        self.detail = detail
        switch detail {
        case .run: view = .actions
        case .pullRequest: view = .pullRequests
        case .repositories: break
        }
    }

    public mutating func closeDetail() {
        detail = nil
    }

    /// Restores the last tab after a restart, for "Where I left off".
    public mutating func restore(view: GitHubView) {
        self.view = view
    }

    /// What the notch should show right now.
    public func effectiveContent(claudeNeedsOwner: Bool, gitHubAvailable: Bool) -> NotchContent {
        guard content == .github, gitHubAvailable, !claudeNeedsOwner else { return .claude }
        return .github
    }
}
