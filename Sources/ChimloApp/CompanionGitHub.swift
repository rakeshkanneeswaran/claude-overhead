import ChimloCore
import SwiftUI

/// The one GitHub destination. Using GitHub (Overview, Repositories, Actions,
/// Pull Requests, Reviews) and configuring it (Integration) are sections of
/// the same page, on the same `GitHubModel` and the same settings that GitHub
/// Mode in the notch reads. Choosing a focused repository here focuses it there.
struct GitHubPage: View {
    @EnvironmentObject private var github: GitHubModel
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var navigation: CompanionNavigation
    @Environment(\.overheadPalette) private var palette
    @State private var tab: GitHubPageTab?
    /// nil shows every monitored repository; otherwise one repository id.
    @State private var scope: Int64?
    @State private var filter: GitHubPRFilter = .open
    @State private var selectedRun: Int?
    @State private var selectedPR: Int?

    private var currentTab: GitHubPageTab {
        tab ?? GitHubPageTab.landing(
            enabled: settings.settings.github.enabled,
            connected: github.connection.isConnected,
            monitoredRepositories: github.snapshots.count
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .padding(.bottom, 14)
            Picker("Section", selection: Binding(get: { currentTab }, set: { tab = $0 })) {
                ForEach(GitHubPageTab.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            if currentTab == .integration {
                GitHubIntegrationView()
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        operational
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear(perform: consumeRequest)
        .onChange(of: github.companionRequest) { _, _ in consumeRequest() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusLine).font(.system(size: 13)).foregroundStyle(palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            if github.connection.isConnected {
                Button { github.refreshNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(github.isRefreshing)
                    .help(github.lastRefresh.map { "Updated \(CompanionFormat.relative($0))" } ?? "Refresh now")
            }
            Button { tab = .integration } label: { Label("Integration", systemImage: "slider.horizontal.3") }
                .help("Sign-in, monitored repositories and GitHub preferences")
        }
    }

    private var statusColor: Color {
        switch github.connection {
        case .connected: palette.success
        case .checking: palette.warning
        case .off: palette.textTertiary
        case .signedOut, .failed: palette.failure
        }
    }

    private var statusLine: String {
        let count = github.snapshots.count
        let monitored = "\(count) \(count == 1 ? "repository" : "repositories") monitored"
        switch github.connection {
        case let .connected(login, source):
            return "Connected as \(login) via \(source == .githubCLI ? "GitHub CLI" : "personal access token") · \(monitored)"
        case .checking: return "Connecting to GitHub…"
        case .off: return "GitHub is off"
        case .signedOut: return "Not signed in"
        case let .failed(reason): return reason
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var operational: some View {
        if !settings.settings.github.enabled || !github.connection.isConnected {
            EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: connectionTitle, message: connectionText)
            Button("Set up GitHub") { tab = .integration }
                .frame(maxWidth: .infinity)
        } else if github.snapshots.isEmpty {
            EmptyStateView(symbol: "square.stack.3d.up", title: "No repositories monitored yet",
                           message: "Choose the repositories to watch in Integration. Pick as many as you like, across your organizations.")
            Button("Choose repositories") { tab = .integration }
                .frame(maxWidth: .infinity)
        } else {
            if currentTab == .actions || currentTab == .pullRequests {
                scopePicker
            }
            switch currentTab {
            case .overview: overview
            case .repositories: repositories
            case .actions: actions
            case .pullRequests: pullRequests
            case .reviews: reviews
            case .integration: EmptyView()
            }
            footer
        }
    }

    private var connectionTitle: String {
        settings.settings.github.enabled ? "GitHub isn't connected" : "GitHub is off"
    }

    private var connectionText: String {
        switch github.connection {
        case .off: "Turn GitHub on in Integration, sign in, and choose the repositories to watch."
        case .checking: "Connecting to GitHub…"
        case .signedOut: "Sign in with `gh auth login`, or save a token in Integration."
        case let .failed(reason): "\(reason) Fix it in Integration."
        case .connected: ""
        }
    }

    /// The notch, another page or a shortcut asked for a section or a detail.
    private func consumeRequest() {
        guard let request = github.companionRequest else { return }
        github.companionRequest = nil
        tab = request.tab
        guard case let .detail(detail) = request else { return }
        switch detail {
        case let .run(repositoryID, runID):
            scope = repositoryID
            github.focus(repositoryID)
            selectedRun = runID
        case let .pullRequest(repositoryID, number):
            scope = repositoryID
            github.focus(repositoryID)
            filter = .all
            selectedPR = number
        case .repositories:
            break
        }
    }

    private var scopedSnapshots: [GitHubRepoSnapshot] {
        guard let scope else { return github.snapshots }
        return github.snapshots.filter { $0.id == scope }
    }

    private var scopePicker: some View {
        Picker("Repository", selection: Binding(
            get: { scope ?? 0 },
            set: { value in
                scope = value == 0 ? nil : value
                if value != 0 { github.focus(value) }
                selectedRun = nil
                selectedPR = nil
            }
        )) {
            Text("All monitored repositories").tag(Int64(0))
            ForEach(github.snapshots) { Text($0.ref.fullName).tag($0.id) }
        }
        .frame(maxWidth: 360)
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        if github.isAwaitingFirstData {
            ProgressView("Loading your repositories…").controlSize(.small)
        } else {
            overviewContent
        }
    }

    private var overviewContent: some View {
        let overview = github.overview
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatTile(label: "Open pull requests", value: "\(overview.openPullRequests)")
                StatTile(label: "Running", value: "\(overview.runningRuns)", tint: overview.runningRuns > 0 ? palette.working : nil)
                StatTile(label: "Failed workflows", value: "\(overview.failedWorkflows)", tint: overview.failedWorkflows > 0 ? palette.failure : nil)
                StatTile(label: "Reviews waiting", value: "\(overview.reviewsWaiting)", tint: overview.reviewsWaiting > 0 ? palette.warning : nil)
            }
            Card("Needs you") {
                if overview.attention.isEmpty {
                    Text("Nothing in your repositories needs you right now.").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                }
                ForEach(Array(overview.attention.enumerated()), id: \.offset) { _, item in
                    Button { open(item) } label: { attentionLine(item) }.buttonStyle(.plain)
                }
            }
            if let latest = overview.latestActivity {
                Text("Latest activity \(CompanionFormat.relative(latest))").font(.system(size: 11)).foregroundStyle(palette.textTertiary)
            }
        }
    }

    private func attentionLine(_ item: GitHubAttention) -> some View {
        let (symbol, color, title, detail): (String, Color, String, String) = {
            switch item {
            case let .failedRun(run): ("xmark.circle.fill", palette.failure, "\(run.name) failed", "\(run.repository) · \(run.branch ?? "")")
            case let .mergeConflict(pr): ("arrow.triangle.merge", palette.failure, "#\(pr.number) has merge conflicts", "\(pr.repository) · \(pr.title)")
            case let .changesRequested(pr): ("exclamationmark.bubble", palette.failure, "#\(pr.number) changes requested", "\(pr.repository) · \(pr.title)")
            case let .ciFailing(pr): ("xmark.octagon", palette.failure, "#\(pr.number) checks failing", "\(pr.repository) · \(pr.title)")
            case let .reviewRequested(pr): ("eye", palette.warning, "Review #\(pr.number)", "\(pr.repository) · \(pr.title)")
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.textPrimary)
            Text(detail).font(.system(size: 11)).foregroundStyle(palette.textSecondary).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.textTertiary)
        }
        .contentShape(Rectangle())
    }

    private func open(_ item: GitHubAttention) {
        switch item {
        case let .failedRun(run):
            guard let id = github.repositoryID(named: run.repository) else { return }
            scope = id; github.focus(id); tab = .actions; selectedRun = run.id
        case let .mergeConflict(pr), let .changesRequested(pr), let .ciFailing(pr), let .reviewRequested(pr):
            guard let id = github.repositoryID(named: pr.repository) else { GitHubModel.openWebPage(pr.url); return }
            scope = id; github.focus(id); tab = .pullRequests; filter = .all; selectedPR = pr.number
        }
    }

    // MARK: Repositories

    private var repositories: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(github.snapshots) { snapshot in
                Card(snapshot.ref.fullName, trailing: AnyView(HStack(spacing: 8) {
                    if github.focusedSnapshot?.id == snapshot.id { Pill(text: "Focused", color: palette.working) }
                    if snapshot.ref.isPrivate == true { Pill(text: "Private") }
                    Button("Focus") { github.focus(snapshot.id) }.controlSize(.small).disabled(github.focusedSnapshot?.id == snapshot.id)
                })) {
                    switch snapshot.availability {
                    case .notFound:
                        Text("GitHub can't find this repository with your sign-in. It may be deleted, renamed beyond reach, or private to someone else. Remove it in Integration.")
                            .font(.system(size: 12)).foregroundStyle(palette.warning)
                    case let .forbidden(message):
                        Text(message ?? "This sign-in can't read part of this repository.").font(.system(size: 12)).foregroundStyle(palette.warning)
                    case let .failed(message):
                        Text("Last refresh failed: \(message)").font(.system(size: 12)).foregroundStyle(palette.warning)
                    case .unknown, .available:
                        KeyValueRow(key: "Open pull requests", value: "\(snapshot.pullRequests.filter(\.isOpen).count)")
                        KeyValueRow(key: "Running workflows", value: "\(snapshot.activeRuns.count)")
                        KeyValueRow(key: "Failing workflows", value: "\(snapshot.failingRuns.count)")
                        if let updated = snapshot.lastUpdated { KeyValueRow(key: "Refreshed", value: CompanionFormat.relative(updated)) }
                    }
                }
            }
            Button("Change monitored repositories") { tab = .integration }
        }
    }

    // MARK: Actions

    private var actions: some View {
        let runs = scopedSnapshots.flatMap(\.runs).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        return HStack(alignment: .top, spacing: 16) {
            Card("Workflow runs") {
                if runs.isEmpty {
                    Text(settings.settings.github.monitorActions ? "No recent runs." : "Actions monitoring is off in Integration.")
                        .font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                }
                ForEach(runs.prefix(40)) { run in
                    Button { selectedRun = run.id } label: {
                        HStack(spacing: 8) {
                            CIBadge(state: run.ciState)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.name).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.textPrimary).lineLimit(1)
                                Text([scope == nil ? run.repository : nil, run.branch, run.shortSha, run.event].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(palette.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Text(CompanionFormat.relative(run.updatedAt ?? run.createdAt)).font(.system(size: 11)).foregroundStyle(palette.textTertiary)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selectedRun == run.id ? palette.working.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 320)
            if let runID = selectedRun, let run = runs.first(where: { $0.id == runID }),
               let repositoryID = github.repositoryID(named: run.repository) {
                runDetail(run, repositoryID: repositoryID)
            }
        }
    }

    private func runDetail(_ run: GitHubWorkflowRun, repositoryID: Int64) -> some View {
        Card(run.name, trailing: AnyView(Button("Open on GitHub") { GitHubModel.openWebPage(run.url) }.controlSize(.small))) {
            KeyValueRow(key: "Status", value: run.runStatus.label)
            KeyValueRow(key: "Repository", value: run.repository)
            if let branch = run.branch { KeyValueRow(key: "Branch", value: branch) }
            if let sha = run.shortSha { KeyValueRow(key: "Commit", value: [sha, run.commitMessage].compactMap { $0 }.joined(separator: " ")) }
            if let event = run.event { KeyValueRow(key: "Event", value: event) }
            if let actor = run.actor { KeyValueRow(key: "Triggered by", value: actor) }
            if let started = run.startedAt ?? run.createdAt { KeyValueRow(key: "Started", value: CompanionFormat.relative(started)) }
            if let duration = GitHubFormat.duration(run.duration ?? run.elapsed(at: .now)) {
                KeyValueRow(key: run.runStatus.isActive ? "Elapsed" : "Duration", value: duration)
            }
            Divider()
            switch github.jobs[run.id] {
            case nil, .loading?:
                ProgressView("Loading jobs…").controlSize(.small)
            case let .failed(message)?:
                Text("Couldn't load jobs: \(message)").font(.system(size: 12)).foregroundStyle(palette.warning)
            case let .loaded(jobs, _)?:
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(job.name).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.textPrimary)
                            Pill(text: job.runStatus.label, color: job.runStatus == .failure ? palette.failure : job.runStatus == .success ? palette.success : nil)
                            Spacer()
                            if let duration = GitHubFormat.duration(job.duration) { Text(duration).font(.system(size: 11)).foregroundStyle(palette.textTertiary) }
                            if let url = job.url { Button("Log") { GitHubModel.openWebPage(url) }.controlSize(.mini) }
                        }
                        ForEach(job.steps, id: \.number) { step in
                            HStack(spacing: 6) {
                                Text("\(step.number).").monospacedDigit()
                                Text(step.name)
                                Spacer()
                                Text(step.runStatus.label)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(step.runStatus == .failure ? palette.failure : palette.textSecondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("Logs open on github.com. Overhead doesn't download them: they come from another server and can be very large.")
                    .font(.system(size: 11)).foregroundStyle(palette.textTertiary)
            }
        }
        .frame(minWidth: 320)
        .task(id: "\(run.id)|\(run.status ?? "")|\(run.conclusion ?? "")") {
            github.loadJobs(runID: run.id, repositoryID: repositoryID, force: true)
        }
    }

    // MARK: Pull requests

    private var pullRequests: some View {
        let all = scopedSnapshots.flatMap(\.allPullRequests)
        let pulls = filter.apply(all).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(GitHubPRFilter.allCases) { option in
                    Text("\(option.displayName) (\(option.apply(all).count))").tag(option)
                }
            }
            .frame(maxWidth: 300)
            HStack(alignment: .top, spacing: 16) {
                Card("Pull requests") {
                    if pulls.isEmpty {
                        Text("No pull requests match.").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                    }
                    ForEach(pulls.prefix(60)) { pr in
                        Button { selectedPR = pr.number; selectedRepositoryForPR = pr.repository } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text("#\(pr.number)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(palette.textSecondary)
                                    Text(pr.title).font(.system(size: 12)).foregroundStyle(palette.textPrimary).lineLimit(1)
                                    if pr.isDraft { Pill(text: "Draft") }
                                    if pr.merged { Pill(text: "Merged", color: palette.waiting) }
                                    Spacer()
                                    CIBadge(state: pr.ciState)
                                    ReviewBadge(state: pr.reviewState)
                                }
                                Text([scope == nil ? pr.repository : nil, pr.headRef.isEmpty ? nil : "\(pr.headRef) → \(pr.baseRef)", pr.author, CompanionFormat.relative(pr.updatedAt)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(palette.textTertiary).lineLimit(1)
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selectedPR == pr.number && selectedRepositoryForPR == pr.repository ? palette.working.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minWidth: 340)
                if let number = selectedPR,
                   let pr = pulls.first(where: { $0.number == number && (selectedRepositoryForPR == nil || $0.repository == selectedRepositoryForPR) })
                    ?? all.first(where: { $0.number == number }),
                   let repositoryID = github.repositoryID(named: pr.repository) {
                    pullRequestDetail(pr, repositoryID: repositoryID)
                }
            }
        }
    }

    @State private var selectedRepositoryForPR: String?

    private func pullRequestDetail(_ pr: GitHubPullRequest, repositoryID: Int64) -> some View {
        let detail = github.pullRequestDetail(number: pr.number, repositoryID: repositoryID)
        return Card("#\(pr.number) \(pr.title)", trailing: AnyView(Button("Open on GitHub") { GitHubModel.openWebPage(pr.url) }.controlSize(.small))) {
            KeyValueRow(key: "State", value: pr.merged ? "Merged" : pr.isOpen ? (pr.isDraft ? "Draft" : "Open") : "Closed")
            if !pr.headRef.isEmpty { KeyValueRow(key: "Branches", value: "\(pr.headRef) → \(pr.baseRef)") }
            if let author = pr.author { KeyValueRow(key: "Author", value: author) }
            if let review = GitHubNotchStyle.label(pr.reviewState) { KeyValueRow(key: "Review", value: review) }
            if pr.ciState != .unknown { KeyValueRow(key: "Checks", value: GitHubRunStatus.from(ciState: pr.ciState).label) }
            if let merge = pr.mergeability.label { KeyValueRow(key: "Merge", value: merge) }
            if settings.settings.github.allowMerging, pr.isOpen {
                CompanionMergeRow(pr: pr, repositoryID: repositoryID)
            }
            switch detail {
            case nil, .loading?:
                ProgressView("Loading details…").controlSize(.small)
            case let .failed(message)?:
                Text("Couldn't load details: \(message)").font(.system(size: 12)).foregroundStyle(palette.warning)
            case let .loaded(value, _)?:
                if let files = value.changedFiles {
                    KeyValueRow(key: "Changes", value: "\(files) files, +\(value.additions ?? 0) −\(value.deletions ?? 0)")
                }
                if let commits = value.commits { KeyValueRow(key: "Commits", value: "\(commits)") }
                if let created = value.createdAt { KeyValueRow(key: "Opened", value: CompanionFormat.relative(created)) }
                if let merged = value.mergedAt { KeyValueRow(key: "Merged", value: CompanionFormat.relative(merged)) }
                if let body = value.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                    Divider()
                    Text(body).font(.system(size: 12)).foregroundStyle(palette.textSecondary).textSelection(.enabled)
                }
                if !value.reviews.isEmpty {
                    Divider()
                    Text("Reviews").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                    ForEach(Array(value.reviews.enumerated()), id: \.offset) { _, review in
                        KeyValueRow(key: review.author, value: "\(review.label)\(review.submittedAt.map { ", " + CompanionFormat.relative($0) } ?? "")")
                    }
                }
                if !value.checks.isEmpty {
                    Divider()
                    Text("Checks").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textTertiary)
                    ForEach(value.checks) { check in
                        HStack {
                            Text(check.name).font(.system(size: 12)).foregroundStyle(palette.textPrimary)
                            Spacer()
                            Pill(text: check.runStatus.label, color: check.runStatus == .failure ? palette.failure : check.runStatus == .success ? palette.success : nil)
                            if let url = check.url { Button("Open") { GitHubModel.openWebPage(url) }.controlSize(.mini) }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 340)
        .task(id: "\(repositoryID)#\(pr.number)") {
            github.loadPullRequestDetail(number: pr.number, repositoryID: repositoryID)
            github.loadRepositorySettings(repositoryID)
        }
    }

    // MARK: Reviews

    private var reviews: some View {
        let viewer = github.viewerLogin?.lowercased()
        let mine = github.snapshots.flatMap(\.pullRequests).filter { $0.isOpen && $0.author?.lowercased() == viewer }
        let changes = mine.filter { $0.reviewState == .changesRequested }
        let approved = mine.filter { $0.reviewState == .approved }
        let waitingOnOthers = mine.filter { $0.reviewState == .reviewRequired }
        return VStack(alignment: .leading, spacing: 14) {
            Card("Waiting on your review") {
                if !settings.settings.github.reviewNotifications {
                    Text("Review requests are off in Integration.").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                } else if github.reviewRequests.isEmpty {
                    Text("No pull requests are waiting on your review.").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                }
                ForEach(github.reviewRequests) { pr in reviewLine(pr) }
            }
            reviewCard("Changes requested on your pull requests", changes, empty: "None of your open pull requests has requested changes.")
            reviewCard("Approved", approved, empty: "None of your open pull requests is approved yet.")
            reviewCard("Waiting for reviewers", waitingOnOthers, empty: "None of your open pull requests is waiting for a reviewer.")
        }
    }

    private func reviewCard(_ title: String, _ prs: [GitHubPullRequest], empty: String) -> some View {
        Card(title) {
            if prs.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(palette.textSecondary)
            }
            ForEach(prs) { pr in reviewLine(pr) }
        }
    }

    private func reviewLine(_ pr: GitHubPullRequest) -> some View {
        HStack {
            PullRequestLine(pr: pr)
            if let id = github.repositoryID(named: pr.repository) {
                Button("Details") {
                    scope = id; github.focus(id); tab = .pullRequests; filter = .all
                    selectedPR = pr.number; selectedRepositoryForPR = pr.repository
                }
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let refreshed = github.lastRefresh { Text("Updated \(CompanionFormat.relative(refreshed))") }
            if let remaining = github.rateLimit?.remaining { Text("· \(remaining) API requests left this hour") }
            Spacer()
            Button("Refresh now") { github.refreshNow() }.disabled(github.isRefreshing)
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.textTertiary)
    }
}

/// Merge in the companion window, with the same rules as the notch: only
/// when GitHub says the pull request can merge, and only after a confirmation
/// naming the method and the branch.
private struct CompanionMergeRow: View {
    let pr: GitHubPullRequest
    let repositoryID: Int64
    @EnvironmentObject private var github: GitHubModel
    @Environment(\.overheadPalette) private var palette
    @State private var method: GitHubMergeMethod = .merge
    @State private var confirming = false

    var body: some View {
        let eligibility = github.mergeEligibility(number: pr.number, repositoryID: repositoryID)
        let state = github.mergeState(number: pr.number, repositoryID: repositoryID)
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .merging?:
                ProgressView("Merging…").controlSize(.small)
            case .merged?:
                Label("Merged into \(pr.baseRef)", systemImage: "checkmark.circle.fill").foregroundStyle(palette.success)
            case let .failed(message)?:
                Text(message).font(.system(size: 12)).foregroundStyle(palette.warning)
                mergeControls(eligibility)
            case nil:
                mergeControls(eligibility)
            }
        }
        .onAppear { method = github.preferredMergeMethod(for: repositoryID) }
        .confirmationDialog(
            "\(method.displayName): #\(pr.number) into \(pr.baseRef)?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(method.shortName) { github.merge(number: pr.number, repositoryID: repositoryID, method: method) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This merges on GitHub for everyone. It only goes ahead if no one has pushed to the branch since you loaded it.")
        }
    }

    @ViewBuilder
    private func mergeControls(_ eligibility: GitHubMergeEligibility?) -> some View {
        if eligibility == .eligible {
            HStack {
                let methods = github.mergeMethods(for: repositoryID)
                if methods.count > 1 {
                    Picker("Method", selection: $method) {
                        ForEach(methods) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Button("Merge pull request…") {
                    github.clearMergeState(number: pr.number, repositoryID: repositoryID)
                    confirming = true
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.success)
            }
        } else if let reason = eligibility?.reason {
            Text("Can't merge yet. \(reason)").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
        }
    }
}
