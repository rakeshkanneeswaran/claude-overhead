import Foundation

/// Where the owner is in a What's New walkthrough: an overview page, then
/// one page per card.
public struct WhatsNewWalkthrough: Equatable, Sendable {
    public enum Page: Equatable, Sendable {
        case overview
        /// The index of the card in the notes.
        case card(Int)
    }

    public let cardCount: Int
    public private(set) var index = 0

    public init(cardCount: Int) {
        self.cardCount = max(0, cardCount)
    }

    public var pageCount: Int { cardCount + 1 }

    public var page: Page { index == 0 ? .overview : .card(index - 1) }

    public var canGoBack: Bool { index > 0 }

    public var canGoForward: Bool { index < pageCount - 1 }

    public var isLastPage: Bool { !canGoForward }

    public mutating func next() {
        if canGoForward { index += 1 }
    }

    public mutating func previous() {
        if canGoBack { index -= 1 }
    }

    /// Jumps to a page; anything outside the walkthrough is ignored.
    public mutating func go(to page: Int) {
        if (0..<pageCount).contains(page) { index = page }
    }

    public mutating func open(card: Int) {
        go(to: card + 1)
    }

    /// "Overview", then "2 of 5".
    public var progressLabel: String {
        switch page {
        case .overview: "Overview"
        case let .card(card): "\(card + 1) of \(cardCount)"
        }
    }

    /// What VoiceOver says for the same thing.
    public var accessibilityProgress: String {
        switch page {
        case .overview: "Overview, \(cardCount) change\(cardCount == 1 ? "" : "s") follow"
        case let .card(card): "Change \(card + 1) of \(cardCount)"
        }
    }
}

/// What the bottom of the What's New window offers, given where the update
/// stands. The window never installs on its own: only "Update Now" does.
public enum WhatsNewUpdateStage: Equatable, Sendable {
    /// Nothing is running: "Update Now" is offered.
    case ready
    /// Downloading, verifying, installing or restarting.
    case working(label: String, progress: Double?)
    case failed(summary: String, recovery: String, canRetry: Bool, showsInstallCommand: Bool)
    /// A new check found nothing to install any more.
    case upToDate

    public init(phase: AppUpdatePhase?) {
        guard let phase else {
            self = .ready
            return
        }
        let presentation = AppUpdatePresentation(phase: phase)
        switch phase {
        case .available, .updated:
            self = .ready
        case .upToDate:
            self = .upToDate
        case .checking, .downloading, .preparing, .installing, .restarting:
            self = .working(label: presentation.title, progress: presentation.normalizedProgress)
        case let .failed(failure):
            self = .failed(
                summary: failure.summary,
                recovery: failure.recovery,
                canRetry: failure.isRetryable,
                showsInstallCommand: failure.suggestsInstallCommand
            )
        }
    }

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

/// What Settings says about updates, in one place for both Settings screens.
public struct UpdateStatusSummary: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case neutral
        case busy
        case good
        case offer
        case problem
    }

    public let tone: Tone
    public let title: String
    public let detail: String

    public init(phase: AppUpdatePhase?, installedVersion: String?) {
        let installed = installedVersion.map { "Claude Overhead \($0)" } ?? "This development build"
        guard let phase else {
            tone = .neutral
            title = installed
            detail = "Updates are checked every hour, or when you ask."
            return
        }
        let presentation = AppUpdatePresentation(phase: phase)
        switch phase {
        case .checking:
            tone = .busy
            title = "Checking for updates…"
            detail = installed + " is installed."
        case let .available(version):
            tone = .offer
            title = version.map { "Version \($0) is available" } ?? "An update is available"
            detail = installedVersion.map { "You have \($0). See what's new, then update when you're ready." }
                ?? "See what's new, then update when you're ready."
        case .upToDate:
            tone = .good
            title = "You're up to date"
            detail = installed + " is the latest version."
        case .downloading, .preparing, .installing, .restarting:
            tone = .busy
            title = presentation.title
            detail = "Your settings and sessions stay as they are."
        case let .updated(version):
            tone = .good
            title = "Updated to \(version)"
            detail = "You're on the latest version."
        case let .failed(failure):
            tone = .problem
            title = "Update failed: \(failure.summary)"
            detail = failure.recovery
        }
    }
}
