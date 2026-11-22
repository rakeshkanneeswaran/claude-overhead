import ChimloCore
import SwiftUI

// MARK: - Actions

struct GitHubActionsList: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        if let snapshot = github.focusedSnapshot {
            let runs = snapshot.runs
            let limit = model.github.density.rowLimit * 2
            ScrollView {
                VStack(spacing: 2) {
                    if case .notFound = snapshot.availability {
                        GitHubInlineNote(text: "\(snapshot.ref.fullName) is gone or no longer visible to this sign-in.", color: ChimloTheme.attention)
                    } else if case let .forbidden(message) = snapshot.availability {
                        GitHubInlineNote(text: message ?? "This sign-in can't read Actions here.", color: ChimloTheme.attention)
                    } else if case let .failed(message) = snapshot.availability {
                        GitHubInlineNote(text: "Couldn't refresh: \(message)", color: ChimloTheme.attention)
                    }
                    if runs.isEmpty {
                        GitHubListEmpty(
                            symbol: "bolt.horizontal.circle",
                            text: snapshot.lastUpdated == nil
                                ? (snapshot.availability == .unknown ? "Loading workflow runs…" : "No workflow runs to show.")
                                : "No recent workflow runs in \(snapshot.ref.name)."
                        )
                    }
                    ForEach(runs.prefix(limit)) { run in
                        GitHubRunRow(model: model, run: run) {
                            model.openGitHubDetail(.run(repositoryID: snapshot.id, runID: run.id))
                        }
                    }
                    if runs.count > limit {
                        GitHubMoreButton(model: model, count: runs.count)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct GitHubRunRow: View {
    @ObservedObject var model: ApplicationModel
    let run: GitHubWorkflowRun
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                GitHubStatusGlyph(status: run.runStatus, reduceMotion: model.reducesMotion)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(run.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChimloTheme.paper).lineLimit(1)
                        if let number = run.runNumber {
                            Text("#\(number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(ChimloTheme.mutedPaper)
                        }
                    }
                    if model.github.showsDetailedMetadata {
                        Text(metadata).font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                timing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, model.github.density == .compact ? 5 : 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(run.runStatus == .failure ? ChimloTheme.raisedFailureInk.opacity(0.55) : ChimloTheme.raisedInk))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.name), \(run.runStatus.label)")
    }

    private var metadata: String {
        [run.branch, run.shortSha, run.event?.replacingOccurrences(of: "_", with: " "), run.commitMessage]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var timing: some View {
        if run.runStatus.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(GitHubFormat.duration(run.elapsed(at: context.date)) ?? run.runStatus.label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(GitHubNotchStyle.color(run.runStatus))
            }
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(run.runStatus == .failure ? "Failed" : GitHubFormat.duration(run.duration) ?? run.runStatus.label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(run.runStatus == .failure ? ChimloTheme.clayText : ChimloTheme.quietPaper)
                if let ago = GitHubFormat.ago(run.updatedAt) {
                    Text(ago).font(.system(size: 9.5)).foregroundStyle(ChimloTheme.mutedPaper)
                }
            }
        }
    }
}

// MARK: - Pull requests

struct GitHubPullRequestList: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        if let snapshot = github.focusedSnapshot {
            let filter = model.githubNavigation.pullRequestFilter
            let pulls = filter.apply(snapshot.allPullRequests)
            let limit = model.github.density.rowLimit * 2
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    ForEach(GitHubPRFilter.allCases) { option in
                        Button {
                            model.githubNavigation.pullRequestFilter = option
                        } label: {
                            Text("\(option.displayName) (\(option.apply(snapshot.allPullRequests).count))")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 9, weight: .bold))
                        Text(filter.displayName).font(.system(size: 11, weight: .semibold))
                        Text("\(pulls.count)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(ChimloTheme.mutedPaper)
                    }
                    .foregroundStyle(ChimloTheme.quietPaper)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .accessibilityLabel("Filter: \(filter.displayName)")
                ScrollView {
                    VStack(spacing: 2) {
                        if pulls.isEmpty {
                            GitHubListEmpty(symbol: "arrow.triangle.pull", text: emptyText(filter, snapshot))
                        }
                        ForEach(pulls.prefix(limit)) { pr in
                            GitHubPullRequestRow(model: model, pr: pr) {
                                model.openGitHubDetail(.pullRequest(repositoryID: snapshot.id, number: pr.number))
                            }
                        }
                        if pulls.count > limit { GitHubMoreButton(model: model, count: pulls.count) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func emptyText(_ filter: GitHubPRFilter, _ snapshot: GitHubRepoSnapshot) -> String {
        if case let .failed(message) = snapshot.availability { return "Couldn't refresh: \(message)" }
        if snapshot.lastUpdated == nil { return snapshot.availability == .unknown ? "Loading pull requests…" : "No pull requests to show." }
        return filter == .all || filter == .open
            ? "No open pull requests in \(snapshot.ref.name)."
            : "No pull requests match “\(filter.displayName)”."
    }
}

struct GitHubPullRequestRow: View {
    @ObservedObject var model: ApplicationModel
    let pr: GitHubPullRequest
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(stateColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("#\(pr.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(ChimloTheme.mutedPaper)
                        Text(pr.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChimloTheme.paper).lineLimit(1)
                    }
                    if model.github.showsDetailedMetadata {
                        Text(metadata).font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    if pr.isOpen, pr.ciState != .unknown {
                        GitHubStatusGlyph(status: .from(ciState: pr.ciState), size: 10, reduceMotion: model.reducesMotion)
                    }
                    if pr.isOpen, let label = GitHubNotchStyle.label(pr.reviewState), pr.reviewState != .commented {
                        Text(shortReview(label))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(GitHubNotchStyle.color(pr.reviewState))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, model.github.density == .compact ? 5 : 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChimloTheme.raisedInk))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func shortReview(_ label: String) -> String {
        switch pr.reviewState {
        case .changesRequested: "Changes"
        case .reviewRequired: "Review"
        default: label
        }
    }

    private var metadata: String {
        var parts: [String] = []
        if !pr.headRef.isEmpty { parts.append("\(pr.headRef) → \(pr.baseRef)") }
        if let author = pr.author { parts.append(author) }
        if pr.isDraft { parts.append("draft") }
        if let ago = GitHubFormat.ago(pr.updatedAt) { parts.append(ago) }
        return parts.joined(separator: " · ")
    }

    private var stateSymbol: String {
        if pr.merged { return "arrow.triangle.merge" }
        if !pr.isOpen { return "xmark.circle" }
        if pr.isDraft { return "circle.dashed" }
        return "arrow.triangle.pull"
    }

    private var stateColor: Color {
        if pr.merged { return Color(red: 0.66, green: 0.55, blue: 0.95) }
        if !pr.isOpen { return ChimloTheme.mutedPaper }
        if pr.isDraft { return ChimloTheme.mutedPaper }
        return ChimloTheme.liveGreen
    }
}

// MARK: - Run detail

struct GitHubRunDetailView: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel
    let repositoryID: Int64
    let runID: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GitHubBackBar(title: "Actions") { model.closeGitHubDetail() }
            if let run = github.run(runID, in: repositoryID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 8) {
                            GitHubStatusGlyph(status: run.runStatus, size: 14, reduceMotion: model.reducesMotion)
                            Text(run.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(ChimloTheme.paper).lineLimit(2)
                            Spacer()
                            Text(run.runStatus.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(GitHubNotchStyle.color(run.runStatus))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            GitHubFactRow("Repository", run.repository)
                            if let branch = run.branch { GitHubFactRow("Branch", branch) }
                            if let sha = run.shortSha { GitHubFactRow("Commit", [sha, run.commitMessage].compactMap { $0 }.joined(separator: "  ")) }
                            if let event = run.event { GitHubFactRow("Event", event.replacingOccurrences(of: "_", with: " ")) }
                            if let actor = run.actor { GitHubFactRow("Triggered by", actor) }
                            if let started = GitHubFormat.ago(run.startedAt ?? run.createdAt) { GitHubFactRow("Started", started) }
                            if run.runStatus.isActive {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    GitHubFactRow("Elapsed", GitHubFormat.duration(run.elapsed(at: context.date)) ?? "Not started")
                                }
                            } else if let duration = GitHubFormat.duration(run.duration) {
                                GitHubFactRow("Duration", duration)
                            }
                            if let attempt = run.runAttempt, attempt > 1 { GitHubFactRow("Attempt", "\(attempt)") }
                        }
                        jobs(run)
                    }
                }
                .scrollIndicators(.hidden)
                HStack(spacing: 6) {
                    Button("Open on GitHub") { GitHubModel.openWebPage(run.url) }.buttonStyle(GitHubPillButtonStyle(prominent: true))
                    if let failedJob = failedJobs.first, let url = failedJob.url {
                        Button("Open log") { GitHubModel.openWebPage(url) }.buttonStyle(GitHubPillButtonStyle())
                            .help("Opens \(failedJob.name)'s log on github.com")
                    }
                    Spacer()
                    Button("More detail") { model.openGitHubInCompanion?(.run(repositoryID: repositoryID, runID: runID)) }
                        .buttonStyle(GitHubPillButtonStyle())
                }
                .task(id: "\(run.id)|\(run.status ?? "")|\(run.conclusion ?? "")|\(github.connection.isConnected)") {
                    github.loadJobs(runID: run.id, repositoryID: repositoryID, force: true)
                }
            } else {
                GitHubListEmpty(symbol: "clock.arrow.circlepath", text: "This run is no longer in the recent list.")
            }
        }
    }

    private var failedJobs: [GitHubWorkflowJob] {
        (github.jobs[runID]?.value ?? []).filter { $0.runStatus == .failure }
    }

    @ViewBuilder
    private func jobs(_ run: GitHubWorkflowRun) -> some View {
        Text("JOBS").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(ChimloTheme.mutedPaper)
        switch github.jobs[runID] {
        case nil, .loading?:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading jobs…") }
                .font(.system(size: 11)).foregroundStyle(ChimloTheme.mutedPaper)
        case let .failed(message)?:
            GitHubInlineNote(text: "Couldn't load jobs: \(message)", color: ChimloTheme.attention)
        case let .loaded(jobs, _)?:
            if jobs.isEmpty {
                Text("No jobs reported.").font(.system(size: 11)).foregroundStyle(ChimloTheme.mutedPaper)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            GitHubStatusGlyph(status: job.runStatus, size: 10, reduceMotion: model.reducesMotion)
                            Text(job.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(ChimloTheme.paper).lineLimit(1)
                            Spacer()
                            if let duration = GitHubFormat.duration(job.duration) {
                                Text(duration).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(ChimloTheme.mutedPaper)
                            }
                        }
                        ForEach(job.failedSteps, id: \.number) { step in
                            Text("Step \(step.number): \(step.name)")
                                .font(.system(size: 10.5)).foregroundStyle(ChimloTheme.clayText)
                                .padding(.leading, 17).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pull request detail

struct GitHubPullRequestDetailView: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel
    let repositoryID: Int64
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GitHubBackBar(title: "Pull requests") { model.closeGitHubDetail() }
            if let pr = github.pullRequestDetail(number: number, repositoryID: repositoryID)?.value?.pullRequest
                ?? github.pullRequest(number, in: repositoryID) {
                let detail = github.pullRequestDetail(number: number, repositoryID: repositoryID)
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("#\(pr.number) \(pr.title)")
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(ChimloTheme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            GitHubTag(text: pr.merged ? "Merged" : pr.isOpen ? (pr.isDraft ? "Draft" : "Open") : "Closed",
                                      color: pr.merged ? Color(red: 0.66, green: 0.55, blue: 0.95) : pr.isOpen ? ChimloTheme.liveGreen : ChimloTheme.mutedPaper)
                            if let review = GitHubNotchStyle.label(pr.reviewState) {
                                GitHubTag(text: review, color: GitHubNotchStyle.color(pr.reviewState))
                            }
                            if pr.ciState != .unknown {
                                GitHubTag(text: "Checks \(GitHubRunStatus.from(ciState: pr.ciState).label.lowercased())", color: GitHubNotchStyle.color(pr.ciState))
                            }
                            if pr.isOpen, let merge = pr.mergeability.label {
                                GitHubTag(text: merge, color: pr.mergeability == .ready ? ChimloTheme.liveGreen : ChimloTheme.attention)
                            }
                        }
                        if model.github.allowsMerging, pr.isOpen,
                           let eligibility = github.mergeEligibility(number: number, repositoryID: repositoryID),
                           let reason = eligibility.reason {
                            Text("Can't merge yet. \(reason)")
                                .font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            if !pr.headRef.isEmpty { GitHubFactRow("Branches", "\(pr.headRef) → \(pr.baseRef)") }
                            if let author = pr.author { GitHubFactRow("Author", author) }
                            if let value = detail?.value {
                                if let files = value.changedFiles {
                                    GitHubFactRow("Changes", "\(files) files · +\(value.additions ?? 0) −\(value.deletions ?? 0)\(value.commits.map { " · \($0) commits" } ?? "")")
                                }
                                if let created = GitHubFormat.ago(value.createdAt) { GitHubFactRow("Opened", created) }
                                if let merged = GitHubFormat.ago(value.mergedAt) { GitHubFactRow("Merged", merged) }
                            }
                            if let updated = GitHubFormat.ago(pr.updatedAt) { GitHubFactRow("Updated", updated) }
                            if let comments = pr.commentCount, comments > 0 { GitHubFactRow("Comments", "\(comments)") }
                        }
                        detailSections(detail)
                    }
                }
                .scrollIndicators(.hidden)
                GitHubMergeBar(model: model, github: github, repositoryID: repositoryID, number: number, pr: pr)
                    .task(id: "\(repositoryID)#\(number)|\(pr.updatedAt?.timeIntervalSince1970 ?? 0)|\(github.connection.isConnected)") {
                        github.loadPullRequestDetail(number: number, repositoryID: repositoryID)
                        github.loadRepositorySettings(repositoryID)
                        // GitHub works out mergeability lazily; ask once more
                        // if it had not finished the first time.
                        try? await Task.sleep(for: .seconds(3))
                        if github.mergeEligibility(number: number, repositoryID: repositoryID) == .unknown {
                            github.loadPullRequestDetail(number: number, repositoryID: repositoryID, force: true)
                        }
                    }
            } else {
                GitHubListEmpty(symbol: "arrow.triangle.pull", text: "This pull request is no longer in the recent list.")
            }
        }
    }

    @ViewBuilder
    private func detailSections(_ detail: GitHubModel.Load<GitHubPullRequestDetail>?) -> some View {
        switch detail {
        case nil, .loading?:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading reviews and checks…") }
                .font(.system(size: 11)).foregroundStyle(ChimloTheme.mutedPaper)
        case let .failed(message)?:
            GitHubInlineNote(text: "Couldn't load details: \(message)", color: ChimloTheme.attention)
        case let .loaded(value, _)?:
            if let preview = value.bodyPreview(limit: model.github.density == .compact ? 280 : 600) {
                Text(preview.text).font(.system(size: 11)).foregroundStyle(ChimloTheme.quietPaper)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(model.github.density == .compact ? 5 : 10)
            }
            if !value.reviews.isEmpty {
                Text("REVIEWS").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(ChimloTheme.mutedPaper)
                ForEach(Array(value.reviews.prefix(4).enumerated()), id: \.offset) { _, review in
                    HStack(spacing: 6) {
                        Text(review.author).font(.system(size: 11, weight: .medium)).foregroundStyle(ChimloTheme.paper)
                        Text(review.label).font(.system(size: 11)).foregroundStyle(ChimloTheme.quietPaper)
                        Spacer()
                        if let ago = GitHubFormat.ago(review.submittedAt) { Text(ago).font(.system(size: 10)).foregroundStyle(ChimloTheme.mutedPaper) }
                    }
                }
            }
            if !value.checks.isEmpty {
                Text("CHECKS").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(ChimloTheme.mutedPaper)
                ForEach(value.checks.sorted { ($0.runStatus == .failure ? 0 : 1) < ($1.runStatus == .failure ? 0 : 1) }.prefix(6)) { check in
                    HStack(spacing: 7) {
                        GitHubStatusGlyph(status: check.runStatus, size: 10, reduceMotion: model.reducesMotion)
                        Text(check.name).font(.system(size: 11)).foregroundStyle(ChimloTheme.paper).lineLimit(1)
                        Spacer()
                        if let url = check.url {
                            Button { GitHubModel.openWebPage(url) } label: { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)) }
                                .buttonStyle(.plain).foregroundStyle(ChimloTheme.mutedPaper)
                                .accessibilityLabel("Open \(check.name) on GitHub")
                        }
                    }
                }
                if value.checks.count > 6 {
                    Text("\(value.checks.count - 6) more checks on GitHub").font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper)
                }
            }
        }
    }
}

// MARK: - Merging

/// The pull request detail's action row. Merge appears only when GitHub
/// says the pull request can merge, and always asks once more, naming the
/// method and the branch, before anything is sent.
struct GitHubMergeBar: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel
    let repositoryID: Int64
    let number: Int
    let pr: GitHubPullRequest
    @State private var confirming = false
    @State private var method: GitHubMergeMethod = .merge

    var body: some View {
        let state = github.mergeState(number: number, repositoryID: repositoryID)
        let canMerge = model.github.allowsMerging
            && github.mergeEligibility(number: number, repositoryID: repositoryID) == .eligible
        VStack(alignment: .leading, spacing: 6) {
            if case let .failed(message)? = state {
                GitHubInlineNote(text: message, color: ChimloTheme.attention)
            }
            if confirming, canMerge, state == nil {
                confirmRow
            } else {
                HStack(spacing: 6) {
                    switch state {
                    case .merging?:
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Merging…") }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(ChimloTheme.quietPaper)
                    case .merged?:
                        Label("Merged into \(pr.baseRef)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.66, green: 0.55, blue: 0.95))
                    default:
                        if canMerge {
                            Button("Merge…") {
                                github.clearMergeState(number: number, repositoryID: repositoryID)
                                method = github.preferredMergeMethod(for: repositoryID)
                                confirming = true
                            }
                            .buttonStyle(GitHubMergeButtonStyle())
                            .help("Merge #\(pr.number) into \(pr.baseRef). You'll confirm first.")
                        }
                    }
                    Button("Open on GitHub") { GitHubModel.openWebPage(pr.url) }
                        .buttonStyle(GitHubPillButtonStyle(prominent: !canMerge))
                    Spacer()
                    Button("More detail") { model.openGitHubInCompanion?(.pullRequest(repositoryID: repositoryID, number: number)) }
                        .buttonStyle(GitHubPillButtonStyle())
                }
            }
        }
        .onChange(of: canMerge) { _, eligible in if !eligible { confirming = false } }
    }

    private var confirmRow: some View {
        let methods = github.mergeMethods(for: repositoryID)
        return HStack(spacing: 6) {
            if methods.count > 1 {
                Menu {
                    ForEach(methods) { option in
                        Button(option.displayName) { method = option }
                    }
                } label: {
                    Text(method.shortName).font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .foregroundStyle(ChimloTheme.paper)
                .accessibilityLabel("Merge method: \(method.displayName)")
            } else {
                Text(method.shortName).font(.system(size: 11, weight: .semibold)).foregroundStyle(ChimloTheme.paper)
            }
            Text("#\(pr.number) into \(pr.baseRef)?")
                .font(.system(size: 11)).foregroundStyle(ChimloTheme.quietPaper).lineLimit(1)
            Spacer(minLength: 4)
            Button("Cancel") { confirming = false }
                .buttonStyle(GitHubPillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Confirm") {
                github.merge(number: number, repositoryID: repositoryID, method: method)
                confirming = false
            }
            .buttonStyle(GitHubMergeButtonStyle())
            .accessibilityLabel("Confirm \(method.displayName) for pull request \(pr.number) into \(pr.baseRef)")
        }
    }
}

struct GitHubMergeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(ChimloTheme.liveGreen))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Repository switcher

struct GitHubRepositorySwitcher: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GitHubBackBar(title: "Repositories") { model.closeGitHubDetail() }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(github.snapshots) { snapshot in
                        let focused = github.focusedSnapshot?.id == snapshot.id
                        Button {
                            github.focus(snapshot.id)
                            model.closeGitHubDetail()
                        } label: {
                            HStack(spacing: 9) {
                                Group {
                                    // Busy repositories spin like their running workflows.
                                    if !snapshot.availability.isUnavailable, snapshot.failingRuns.isEmpty, !snapshot.activeRuns.isEmpty {
                                        GitHubRunningSpinner(size: 7, reduceMotion: model.reducesMotion)
                                    } else {
                                        Circle().fill(dot(snapshot)).frame(width: 6, height: 6)
                                    }
                                }
                                .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(snapshot.ref.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChimloTheme.paper)
                                    Text(caption(snapshot)).font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper).lineLimit(1)
                                }
                                Spacer()
                                if snapshot.ref.isPrivate == true {
                                    Image(systemName: "lock.fill").font(.system(size: 8.5)).foregroundStyle(ChimloTheme.mutedPaper)
                                        .accessibilityLabel("Private")
                                }
                                if focused {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ChimloTheme.paper)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(focused ? ChimloTheme.selectedInk : ChimloTheme.raisedInk))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(focused ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button("Manage repositories…") { model.openGitHubIntegration?() }.buttonStyle(GitHubPillButtonStyle())
        }
    }

    private func dot(_ snapshot: GitHubRepoSnapshot) -> Color {
        if snapshot.availability.isUnavailable { return ChimloTheme.attention }
        if !snapshot.failingRuns.isEmpty { return ChimloTheme.clayText }
        if !snapshot.activeRuns.isEmpty { return ChimloTheme.liveGreen }
        return ChimloTheme.liveGreen.opacity(0.8)
    }

    private func caption(_ snapshot: GitHubRepoSnapshot) -> String {
        if case .notFound = snapshot.availability { return "\(snapshot.ref.owner) · not found or no access" }
        if case .forbidden = snapshot.availability { return "\(snapshot.ref.owner) · access limited" }
        var parts = [snapshot.ref.owner]
        let open = snapshot.pullRequests.filter(\.isOpen).count
        if open > 0 { parts.append(open == 1 ? "1 open PR" : "\(open) open PRs") }
        if !snapshot.activeRuns.isEmpty { parts.append("\(snapshot.activeRuns.count) running") }
        if !snapshot.failingRuns.isEmpty { parts.append("\(snapshot.failingRuns.count) failing") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Small pieces

struct GitHubBackBar: View {
    let title: String
    let back: () -> Void

    var body: some View {
        Button(action: back) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(ChimloTheme.quietPaper)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Back to \(title)")
    }
}

struct GitHubFactRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(ChimloTheme.mutedPaper).frame(width: 76, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(ChimloTheme.paper).lineLimit(2).textSelection(.enabled)
        }
    }
}

struct GitHubTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct GitHubInlineNote: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

struct GitHubListEmpty: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(ChimloTheme.mutedPaper)
            Text(text).font(.system(size: 11.5)).foregroundStyle(ChimloTheme.quietPaper).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

struct GitHubMoreButton: View {
    @ObservedObject var model: ApplicationModel
    let count: Int

    var body: some View {
        Button("All \(count) in the GitHub window") { model.openGitHubInCompanion?(nil) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ChimloTheme.mutedPaper)
            .padding(.top, 4)
    }
}
