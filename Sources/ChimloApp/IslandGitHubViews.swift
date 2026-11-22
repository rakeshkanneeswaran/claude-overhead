import AppKit
import ChimloCore
import SwiftUI

// MARK: - The GitHub mark

/// GitHub's mark from Primer Octicons (`mark-github`, MIT licence), drawn as a
/// template image so it tints like the other notch controls.
enum GitHubMarkImage {
    static let image: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path fill="#000" d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }()
}

struct GitHubMark: View {
    var size: CGFloat = 12

    var body: some View {
        Image(nsImage: GitHubMarkImage.image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Shared styling

enum GitHubNotchStyle {
    static func color(_ status: GitHubRunStatus) -> Color {
        switch status {
        case .success: ChimloTheme.liveGreen
        case .failure: ChimloTheme.clayText
        case .inProgress, .queued: ChimloTheme.providerBlue
        case .waiting: ChimloTheme.attention
        case .cancelled, .skipped, .neutral, .unknown: ChimloTheme.mutedPaper
        }
    }

    static func color(_ ci: CIState) -> Color {
        color(GitHubRunStatus.from(ciState: ci))
    }

    static func symbol(_ status: GitHubRunStatus) -> String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .queued: "clock"
        case .waiting: "pause.circle"
        case .cancelled: "slash.circle"
        case .skipped: "arrow.uturn.right.circle"
        case .neutral, .unknown: "circle"
        }
    }

    static func color(_ review: GitHubReviewState) -> Color {
        switch review {
        case .approved: ChimloTheme.liveGreen
        case .changesRequested: ChimloTheme.clayText
        case .reviewRequired: ChimloTheme.attention
        case .commented, .none: ChimloTheme.mutedPaper
        }
    }

    static func label(_ review: GitHubReviewState) -> String? {
        switch review {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review requested"
        case .commented: "Commented"
        case .none: nil
        }
    }
}

extension GitHubRunStatus {
    /// For pull request checks, which arrive as a combined `CIState`.
    static func from(ciState: CIState) -> GitHubRunStatus {
        switch ciState {
        case .queued: .queued
        case .inProgress: .inProgress
        case .success: .success
        case .failure: .failure
        case .cancelled: .cancelled
        case .skipped: .skipped
        case .neutral: .neutral
        case .unknown: .unknown
        }
    }
}

enum GitHubFormat {
    static func ago(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }
}

/// A run or check status: a symbol in its colour. Running spins slowly unless
/// the owner asked for less motion.
struct GitHubStatusGlyph: View {
    let status: GitHubRunStatus
    var size: CGFloat = 11
    var reduceMotion = false
    @State private var turning = false

    var body: some View {
        Image(systemName: GitHubNotchStyle.symbol(status))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(GitHubNotchStyle.color(status))
            .rotationEffect(.degrees(status == .inProgress && turning ? 360 : 0))
            .animation(status == .inProgress && !reduceMotion
                ? .linear(duration: 2.4).repeatForever(autoreverses: false)
                : nil, value: turning)
            .onAppear { turning = status == .inProgress && !reduceMotion }
            .onChange(of: status) { _, new in turning = new == .inProgress && !reduceMotion }
            .accessibilityLabel(status.label)
    }
}

// MARK: - The GitHub button

/// The GitHub control in the open notch's status band. Its state is a quiet
/// dot, never a count: red for a failed workflow, amber when something waits
/// on the owner, blue while workflows run, white for new activity.
struct GitHubNotchButton: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        let isActive = model.notchContent == .github
        let indicator = model.github.indicator
        Button(action: model.toggleGitHubMode) {
            GitHubMark(size: 11.5)
                .foregroundStyle(markColor(isActive: isActive, indicator: indicator))
                .overlay(alignment: .topTrailing) {
                    if let dot = dotColor(indicator) {
                        Circle()
                            .fill(dot)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1))
                            .offset(x: 3, y: -2.5)
                            .opacity(indicator == .running && !model.reducesMotion ? 0.85 : 1)
                    }
                }
                .padding(.horizontal, 2)
                .background {
                    if isActive {
                        Capsule().fill(Color.white.opacity(0.12)).frame(width: 22, height: 18)
                    }
                }
        }
        .buttonStyle(GitHubControlButtonStyle())
        .help(helpText(isActive: isActive, indicator: indicator))
        .accessibilityLabel(isActive ? "Back to Claude" : "Open GitHub Mode")
        .accessibilityValue(accessibilityValue(indicator))
    }

    private func markColor(isActive: Bool, indicator: GitHubIndicator) -> Color {
        if isActive { return ChimloTheme.paper }
        return indicator == .unavailable ? ChimloTheme.mutedPaper : ChimloTheme.quietPaper
    }

    private func dotColor(_ indicator: GitHubIndicator) -> Color? {
        switch indicator {
        case .failed: ChimloTheme.clayText
        case .attention: ChimloTheme.attention
        case .running: ChimloTheme.providerBlue
        case .activity: ChimloTheme.paper
        case .idle, .unavailable: nil
        }
    }

    private func helpText(isActive: Bool, indicator: GitHubIndicator) -> String {
        if isActive { return "Back to Claude" }
        switch indicator {
        case .failed: return "GitHub: a workflow failed"
        case .attention: return "GitHub: something needs you"
        case .running: return "GitHub: workflows running"
        case .activity: return "GitHub: new activity"
        case .idle: return "Open GitHub Mode"
        case .unavailable: return "GitHub is signed out or unreachable"
        }
    }

    private func accessibilityValue(_ indicator: GitHubIndicator) -> String {
        switch indicator {
        case .failed: "A workflow failed"
        case .attention: "Something needs you"
        case .running: "Workflows running"
        case .activity: "New activity"
        case .idle: "Up to date"
        case .unavailable: "Unavailable"
        }
    }
}

struct GitHubControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .frame(width: 25, height: 26)
            .contentShape(Rectangle())
    }
}

/// The left wing in GitHub Mode: a way back, saying where the owner is.
struct GitHubModeWing: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        Button(action: model.toggleGitHubMode) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                Text("Claude").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(ChimloTheme.quietPaper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to Claude")
        .accessibilityLabel("Back to Claude")
    }
}

/// The closed notch's GitHub signal: a dot, only for things that need the owner.
struct GitHubClosedNotchDot: View {
    let indicator: GitHubIndicator

    var body: some View {
        Circle()
            .fill(indicator == .failed ? ChimloTheme.clayText : ChimloTheme.attention)
            .frame(width: 5, height: 5)
            .accessibilityLabel(indicator == .failed ? "GitHub workflow failed" : "GitHub needs you")
    }
}

// MARK: - The panel

/// GitHub Mode: overview, Actions and pull requests for the monitored
/// repositories, with details one click away. Everything shown comes from
/// `GitHubModel`; nothing here is sample data.
struct GitHubNotchPanel: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if github.connection.isConnected, !github.snapshots.isEmpty {
                GitHubPanelHeader(model: model, github: github)
            }
            Group {
                if !github.connection.isConnected {
                    GitHubConnectionMessage(model: model, github: github)
                } else if github.snapshots.isEmpty {
                    GitHubEmptySelection(model: model, github: github)
                } else if let detail = model.githubNavigation.detail {
                    switch detail {
                    case let .run(repositoryID, runID):
                        GitHubRunDetailView(model: model, github: github, repositoryID: repositoryID, runID: runID)
                    case let .pullRequest(repositoryID, number):
                        GitHubPullRequestDetailView(model: model, github: github, repositoryID: repositoryID, number: number)
                    case .repositories:
                        GitHubRepositorySwitcher(model: model, github: github)
                    }
                } else {
                    switch model.githubNavigation.view {
                    case .overview: GitHubOverviewView(model: model, github: github)
                    case .actions: GitHubActionsList(model: model, github: github)
                    case .pullRequests: GitHubPullRequestList(model: model, github: github)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
        .animation(model.reducesMotion ? nil : .easeOut(duration: 0.18), value: model.githubNavigation)
    }
}

private struct GitHubPanelHeader: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(GitHubView.allCases) { view in
                let selected = model.githubNavigation.view == view && model.githubNavigation.detail == nil
                Button { model.showGitHub(view) } label: {
                    HStack(spacing: 4) {
                        Text(view == .pullRequests ? "Pull requests" : view.displayName)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        if let dot = tabDot(view) {
                            Circle().fill(dot).frame(width: 4, height: 4)
                        }
                    }
                    .foregroundStyle(selected ? ChimloTheme.paper : ChimloTheme.mutedPaper)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(selected ? ChimloTheme.selectedInk : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 4)
            if model.github.showsRepositoryInfo, let focused = github.focusedSnapshot {
                Button { model.openGitHubDetail(.repositories) } label: {
                    HStack(spacing: 4) {
                        Text(focused.ref.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().stroke(ChimloTheme.rowHoverEdge, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Switch repository: \(focused.ref.fullName)")
                .accessibilityLabel("Repository \(focused.ref.fullName). Switch repository")
            }
        }
    }

    private func tabDot(_ view: GitHubView) -> Color? {
        switch view {
        case .overview: return nil
        case .actions:
            guard let snapshot = github.focusedSnapshot else { return nil }
            if !snapshot.failingRuns.isEmpty { return ChimloTheme.clayText }
            if !snapshot.activeRuns.isEmpty { return ChimloTheme.providerBlue }
            return nil
        case .pullRequests:
            guard let snapshot = github.focusedSnapshot else { return nil }
            return snapshot.pullRequests.contains { $0.ciState == .failure || $0.reviewState == .changesRequested }
                ? ChimloTheme.attention : nil
        }
    }
}

// MARK: - States

private struct GitHubConnectionMessage: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            GitHubMark(size: 22).foregroundStyle(ChimloTheme.mutedPaper)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ChimloTheme.paper)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(ChimloTheme.quietPaper)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            if case .checking = github.connection {
                ProgressView().controlSize(.small)
            } else {
                Button("Open GitHub settings") { model.openGitHubSettings?() }
                    .buttonStyle(GitHubPillButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch github.connection {
        case .off: "GitHub is off"
        case .checking: "Connecting to GitHub…"
        case .signedOut: "Not signed in"
        case .connected: "Connected"
        case .failed: "Can't reach GitHub"
        }
    }

    private var message: String {
        switch github.connection {
        case .off: return "Turn GitHub on in Settings to see your workflows and pull requests here."
        case .checking: return "Checking the GitHub CLI and your Keychain."
        case let .signedOut(cli):
            switch cli {
            case .notInstalled: return "Install the GitHub CLI and run `gh auth login`, or save a token in Settings."
            case .signedOut: return "Run `gh auth login` in Terminal, or save a token in Settings."
            case .signedIn: return "The GitHub CLI is signed in but shared no token. Run `gh auth status` to check."
            }
        case .connected: return ""
        case let .failed(reason): return "\(reason) Claude Mode keeps working as usual."
        }
    }
}

private struct GitHubEmptySelection: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "square.stack.3d.up").font(.system(size: 20)).foregroundStyle(ChimloTheme.mutedPaper)
            Text("No repositories yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(ChimloTheme.paper)
            Text("Choose the repositories to watch. You can pick as many as you like, across your organizations.")
                .font(.system(size: 11.5)).foregroundStyle(ChimloTheme.quietPaper)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("Choose repositories") { model.openGitHubSettings?() }
                .buttonStyle(GitHubPillButtonStyle())
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct GitHubPillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : ChimloTheme.paper)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(prominent ? ChimloTheme.paper : ChimloTheme.hoveredBadgeInk))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Overview

private struct GitHubOverviewView: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        if github.isAwaitingFirstData {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading \(github.snapshots.count == 1 ? "your repository" : "\(github.snapshots.count) repositories")…")
                    .font(.system(size: 11.5)).foregroundStyle(ChimloTheme.quietPaper)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }

    private var content: some View {
        let overview = github.overview
        let limit = model.github.density.rowLimit
        let pending = github.snapshots.filter { $0.lastUpdated == nil && $0.availability == .unknown }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    stat("Open PRs", overview.openPullRequests, ChimloTheme.paper)
                    stat("Running", overview.runningRuns, ChimloTheme.providerBlue)
                    stat("Failed", overview.failedWorkflows, ChimloTheme.clayText)
                    stat("Reviews", overview.reviewsWaiting, ChimloTheme.attention)
                }
                if pending > 0 {
                    Text("Still loading \(pending) of \(github.snapshots.count) repositories.")
                        .font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper)
                }
                Text(overview.attention.isEmpty ? (pending > 0 ? "NOTHING YET" : "ALL CLEAR") : "NEEDS YOU")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(ChimloTheme.mutedPaper)
                if overview.attention.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle").foregroundStyle(ChimloTheme.liveGreen)
                        Text(pending > 0 ? "Nothing needs you in the repositories loaded so far." : "Nothing in your repositories needs you.")
                            .foregroundStyle(ChimloTheme.quietPaper)
                    }
                    .font(.system(size: 11.5))
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(overview.attention.prefix(limit).enumerated()), id: \.offset) { _, item in
                            GitHubAttentionRow(model: model, github: github, item: item)
                        }
                    }
                    if overview.attention.count > limit {
                        Button("Show all \(overview.attention.count) in the GitHub window") { model.openGitHubInCompanion?(nil) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChimloTheme.mutedPaper)
                    }
                }
                footer(overview)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? color : ChimloTheme.mutedPaper)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(ChimloTheme.mutedPaper)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ChimloTheme.raisedInk))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func footer(_ overview: GitHubOverview) -> some View {
        HStack(spacing: 6) {
            if model.github.showsAccount, let login = github.viewerLogin {
                Text(login).foregroundStyle(ChimloTheme.quietPaper)
                Text("·")
            }
            Text(github.snapshots.count == 1 ? "1 repository" : "\(github.snapshots.count) repositories")
            if overview.unavailableRepositories > 0 {
                Text("·")
                Button("\(overview.unavailableRepositories) unavailable") { model.openGitHubSettings?() }
                    .buttonStyle(.plain)
                    .foregroundStyle(ChimloTheme.attention)
            }
            Spacer()
            if let latest = GitHubFormat.ago(overview.latestActivity) {
                Text("Latest \(latest)")
            }
            Button { github.refreshNow() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(github.isRefreshing)
            .help(GitHubFormat.ago(github.lastRefresh).map { "Refreshed \($0). Refresh now" } ?? "Refresh now")
            .accessibilityLabel("Refresh GitHub")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(ChimloTheme.mutedPaper)
        .padding(.top, 2)
    }
}

private struct GitHubAttentionRow: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel
    let item: GitHubAttention

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChimloTheme.paper).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(ChimloTheme.mutedPaper)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChimloTheme.raisedInk))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var repositoryLabel: String? {
        guard model.github.showsRepositoryInfo else { return nil }
        switch item {
        case let .failedRun(run): return run.repository
        case let .mergeConflict(pr), let .changesRequested(pr), let .ciFailing(pr), let .reviewRequested(pr): return pr.repository
        }
    }

    private var symbol: String {
        switch item {
        case .failedRun: "xmark.circle.fill"
        case .mergeConflict: "arrow.triangle.merge"
        case .changesRequested: "exclamationmark.bubble"
        case .ciFailing: "xmark.octagon"
        case .reviewRequested: "eye"
        }
    }

    private var color: Color {
        switch item {
        case .failedRun, .mergeConflict, .changesRequested, .ciFailing: ChimloTheme.clayText
        case .reviewRequested: ChimloTheme.attention
        }
    }

    private var title: String {
        switch item {
        case let .failedRun(run): "\(run.name) failed"
        case let .mergeConflict(pr): "#\(pr.number) has merge conflicts"
        case let .changesRequested(pr): "#\(pr.number) changes requested"
        case let .ciFailing(pr): "#\(pr.number) checks failing"
        case let .reviewRequested(pr): "Review #\(pr.number)"
        }
    }

    private var subtitle: String {
        let detail: String
        switch item {
        case let .failedRun(run): detail = [run.branch, run.shortSha, GitHubFormat.ago(run.updatedAt)].compactMap { $0 }.joined(separator: " · ")
        case let .mergeConflict(pr), let .changesRequested(pr), let .ciFailing(pr), let .reviewRequested(pr): detail = pr.title
        }
        return [repositoryLabel, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func open() {
        switch item {
        case let .failedRun(run):
            guard let id = github.repositoryID(named: run.repository) else { return }
            github.focus(id)
            model.openGitHubDetail(.run(repositoryID: id, runID: run.id))
        case let .mergeConflict(pr), let .changesRequested(pr), let .ciFailing(pr), let .reviewRequested(pr):
            if let id = github.repositoryID(named: pr.repository) {
                github.focus(id)
                model.openGitHubDetail(.pullRequest(repositoryID: id, number: pr.number))
            } else {
                // A review request in a repository Overhead is not watching.
                GitHubModel.openWebPage(pr.url)
            }
        }
    }
}
