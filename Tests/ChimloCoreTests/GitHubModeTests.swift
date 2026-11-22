import Foundation
import Testing
@testable import ChimloCore

// MARK: - Fixtures

private let api = GitHubRepoRef(id: 101, owner: "acme", name: "api", isPrivate: true)
private let web = GitHubRepoRef(id: 102, owner: "acme", name: "web", isPrivate: false)
private let tools = GitHubRepoRef(id: 103, owner: "octo", name: "tools")
/// Same name as `api`, different owner: must stay a different repository.
private let otherAPI = GitHubRepoRef(id: 201, owner: "globex", name: "api")

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func run(
    _ id: Int,
    name: String = "CI",
    repository: String = "acme/api",
    status: String? = "completed",
    conclusion: String? = "success",
    branch: String = "main",
    minute: Int = 0,
    attempt: Int = 1
) -> GitHubWorkflowRun {
    let created = base.addingTimeInterval(TimeInterval(minute * 60))
    return GitHubWorkflowRun(
        id: id, repository: repository, name: name, status: status, conclusion: conclusion,
        branch: branch, headSha: "abcdef1234567", event: "push",
        createdAt: created, startedAt: created, updatedAt: created.addingTimeInterval(90),
        url: "https://github.com/\(repository)/actions/runs/\(id)",
        runAttempt: attempt
    )
}

private func pr(
    _ number: Int,
    repository: String = "acme/api",
    author: String = "alice",
    state: String = "open",
    merged: Bool = false,
    draft: Bool = false,
    review: GitHubReviewState = .none,
    ci: CIState = .unknown,
    mergeable: String? = nil,
    minute: Int = 0
) -> GitHubPullRequest {
    GitHubPullRequest(
        repository: repository, number: number, title: "PR \(number)",
        url: "https://github.com/\(repository)/pull/\(number)", author: author,
        headRef: "feature/\(number)", headRepository: repository, baseRef: "main",
        isDraft: draft, state: state, merged: merged,
        updatedAt: base.addingTimeInterval(TimeInterval(minute * 60)),
        mergeableState: mergeable, reviewState: review, ciState: ci
    )
}

private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "overhead.github.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

// MARK: - Repository selection

@Suite("GitHub repository selection")
struct GitHubRepositorySelectionTests {
    @Test("One repository can be selected, and it becomes the focus")
    func selectOne() {
        var selection = GitHubRepositorySelection()
        selection.select(api)
        #expect(selection.ids == [101])
        #expect(selection.focused == api)
    }

    @Test("Many repositories across owners can be selected at once")
    func selectMany() {
        var selection = GitHubRepositorySelection()
        selection.select(all: [api, web, tools, otherAPI])
        #expect(selection.ids == [101, 102, 103, 201])
        #expect(selection.count == 4)
        // The focus stays on the first pick; adding more does not steal it.
        #expect(selection.focusedID == 101)
    }

    @Test("Same-named repositories under different owners stay separate")
    func duplicateNames() {
        var selection = GitHubRepositorySelection()
        selection.select(api)
        selection.select(otherAPI)
        #expect(selection.count == 2)
        selection.deselect(api.id)
        #expect(selection.repositories == [otherAPI])
    }

    @Test("Selecting something twice keeps one entry and refreshes its name")
    func noDuplicates() {
        var selection = GitHubRepositorySelection()
        selection.select(api)
        selection.select(GitHubRepoRef(id: 101, owner: "acme", name: "api-v2"))
        #expect(selection.count == 1)
        #expect(selection.repositories.first?.name == "api-v2")
        #expect(selection.repositories.first?.isPrivate == true, "unknown visibility keeps the known value")
    }

    @Test("Deselecting one leaves the rest, and the focus moves off it")
    func deselectOne() {
        var selection = GitHubRepositorySelection(repositories: [api, web, tools], focusedID: 102)
        selection.deselect(102)
        #expect(selection.ids == [101, 103])
        #expect(selection.focusedID == 101)
        // Deselecting something not selected changes nothing.
        let before = selection
        selection.deselect(999)
        #expect(selection == before)
    }

    @Test("Deselect all and clear empty the selection, and the focus with it")
    func deselectAll() {
        var selection = GitHubRepositorySelection(repositories: [api, web, tools])
        selection.deselect(all: [api, web])
        #expect(selection.ids == [103])
        selection.clear()
        #expect(selection.isEmpty)
        #expect(selection.focusedID == nil)
        #expect(selection.excludedIDs == [101, 102, 103])
    }

    @Test("A removed repository can be added again, repeatedly")
    func reAdd() {
        var selection = GitHubRepositorySelection()
        for _ in 0..<3 {
            selection.toggle(api)
            #expect(selection.contains(101))
            selection.toggle(api)
            #expect(!selection.contains(101))
        }
        selection.select(api)
        #expect(selection.contains(101))
        #expect(!selection.excludedIDs.contains(101), "adding by hand lifts the exclusion")
    }

    @Test("The focus can only move to a selected repository")
    func focus() {
        var selection = GitHubRepositorySelection(repositories: [api, web])
        selection.focus(102)
        #expect(selection.focused == web)
        selection.focus(103)
        #expect(selection.focusedID == 102)
        // A stored focus that is no longer selected falls back to the first.
        let restored = GitHubRepositorySelection(repositories: [api], focusedID: 102)
        #expect(restored.focusedID == 101)
    }

    @Test("Claude's repositories are added automatically, but never ones the owner removed")
    func adoptClaudeRepositories() {
        var selection = GitHubRepositorySelection(repositories: [api])
        selection.deselect(api.id)
        let added = selection.adoptClaudeRepositories([api, web])
        #expect(added == [web])
        #expect(selection.ids == [102])
        // Following off: nothing is added.
        var manual = GitHubRepositorySelection(followClaudeRepositories: false)
        #expect(manual.adoptClaudeRepositories([api]).isEmpty)
        #expect(manual.isEmpty)
    }

    @Test("A rename keeps the repository's place and selection")
    func rename() {
        var selection = GitHubRepositorySelection(repositories: [api, web], focusedID: 102)
        selection.refresh(GitHubRepoRef(id: 102, owner: "acme-inc", name: "website"))
        #expect(selection.repositories[1].fullName == "acme-inc/website")
        #expect(selection.focusedID == 102)
        // Refreshing something not selected does not add it.
        selection.refresh(tools)
        #expect(!selection.contains(103))
    }

    @Test("The selection round-trips through JSON as a collection of ids")
    func codable() throws {
        var selection = GitHubRepositorySelection(repositories: [api, otherAPI], focusedID: 201)
        selection.deselect(api.id)
        selection.select(web)
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(GitHubRepositorySelection.self, from: data)
        #expect(decoded == selection)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"id\":201"))
    }

    @Test("A malformed entry is dropped on its own; duplicates collapse")
    func lenientDecoding() throws {
        let json = """
        {"repositories": [
            {"id": 101, "owner": "acme", "name": "api"},
            {"owner": "broken"},
            {"id": 101, "owner": "acme", "name": "api"},
            {"id": 103, "owner": "octo", "name": "tools"}
        ], "focusedID": 999, "followClaudeRepositories": "nope"}
        """
        let decoded = try JSONDecoder().decode(GitHubRepositorySelection.self, from: Data(json.utf8))
        #expect(decoded.ids == [101, 103])
        #expect(decoded.focusedID == 101)
        #expect(decoded.followClaudeRepositories)
    }

    @Test("An empty selection is valid and stays empty")
    func emptySelection() throws {
        let decoded = try JSONDecoder().decode(GitHubRepositorySelection.self, from: Data("{}".utf8))
        #expect(decoded.isEmpty)
        #expect(decoded.focused == nil)
    }

    @Test("The selection and focus survive a restart through the settings store")
    func persistence() throws {
        try withIsolatedDefaults { defaults in
            var settings = OverheadSettings()
            settings.github.enabled = true
            settings.github.selection = GitHubRepositorySelection(repositories: [api, web, otherAPI], focusedID: 201)
            settings.github.selection.deselect(web.id)
            SettingsStore(defaults: defaults).save(settings)
            let restarted = SettingsStore(defaults: defaults).load()
            #expect(restarted.github.selection.ids == [101, 201])
            #expect(restarted.github.selection.focusedID == 201)
            #expect(restarted.github.selection.excludedIDs == [102])
        }
    }

    @Test("Search matches owner, name and owner/name, ignoring case")
    func search() {
        let all = [api, web, tools, otherAPI]
        #expect(GitHubRepoSearch.filter(all, query: "API").map(\.id) == [101, 201])
        #expect(GitHubRepoSearch.filter(all, query: "acme/").map(\.id) == [101, 102])
        #expect(GitHubRepoSearch.filter(all, query: "  ").count == 4)
    }

    @Test("Owners group with the viewer's own repositories first")
    func grouping() {
        let groups = GitHubRepoSearch.groupedByOwner([tools, web, api, otherAPI], viewer: "Octo")
        #expect(groups.map(\.owner) == ["octo", "acme", "globex"])
        #expect(groups[1].repositories.map(\.name) == ["api", "web"])
    }

    @Test("Deleted and inaccessible repositories are reported, not silently dropped")
    func unavailable() {
        #expect(GitHubRepoAvailability.notFound.isUnavailable)
        #expect(GitHubRepoAvailability.forbidden("no Actions access").isUnavailable)
        #expect(!GitHubRepoAvailability.failed("timeout").isUnavailable)
        let overview = GitHubOverview.make(
            [GitHubRepoSnapshot(ref: api, availability: .notFound), GitHubRepoSnapshot(ref: web, availability: .available)],
            reviewRequests: [], viewer: nil
        )
        #expect(overview.unavailableRepositories == 1)
    }
}

// MARK: - GitHub Mode

@Suite("GitHub Mode navigation")
struct GitHubModeNavigationTests {
    @Test("Opening GitHub Mode shows the chosen default view")
    func open() {
        var navigation = GitHubNavigation()
        #expect(navigation.content == .claude)
        navigation.openGitHub(defaultView: .actions)
        #expect(navigation.content == .github)
        #expect(navigation.view == .actions)
    }

    @Test("Back to Claude keeps GitHub's place for next time")
    func returnKeepsPlace() {
        var navigation = GitHubNavigation()
        navigation.openGitHub(defaultView: .overview)
        navigation.open(.run(repositoryID: 101, runID: 7))
        navigation.returnToClaude()
        #expect(navigation.content == .claude)
        #expect(navigation.detail == .run(repositoryID: 101, runID: 7))
        navigation.openGitHub(defaultView: .lastActive)
        #expect(navigation.view == .actions)
        #expect(navigation.detail == .run(repositoryID: 101, runID: 7))
        // A fixed default view starts fresh on that tab.
        navigation.returnToClaude()
        navigation.openGitHub(defaultView: .pullRequests)
        #expect(navigation.view == .pullRequests)
        #expect(navigation.detail == nil)
    }

    @Test("Toggling switches between the modes")
    func toggle() {
        var navigation = GitHubNavigation()
        navigation.toggle(defaultView: .overview)
        #expect(navigation.content == .github)
        navigation.toggle(defaultView: .overview)
        #expect(navigation.content == .claude)
    }

    @Test("Claude always wins while it waits on the owner, and GitHub Mode comes back after")
    func claudePriority() {
        var navigation = GitHubNavigation()
        navigation.openGitHub(defaultView: .overview)
        #expect(navigation.effectiveContent(claudeNeedsOwner: true, gitHubAvailable: true) == .claude)
        // Nothing about GitHub's place changed while Claude had the notch.
        #expect(navigation.content == .github)
        #expect(navigation.effectiveContent(claudeNeedsOwner: false, gitHubAvailable: true) == .github)
    }

    @Test("GitHub Mode falls back to Claude when GitHub is off or disconnected")
    func unavailable() {
        var navigation = GitHubNavigation()
        navigation.openGitHub(defaultView: .overview)
        #expect(navigation.effectiveContent(claudeNeedsOwner: false, gitHubAvailable: false) == .claude)
    }

    @Test("Details land on their tab, and closing one returns to the list")
    func details() {
        var navigation = GitHubNavigation()
        navigation.openGitHub(defaultView: .overview)
        navigation.open(.pullRequest(repositoryID: 101, number: 4))
        #expect(navigation.view == .pullRequests)
        navigation.closeDetail()
        #expect(navigation.detail == nil)
        #expect(navigation.view == .pullRequests)
        navigation.open(.repositories)
        navigation.show(.overview)
        #expect(navigation.detail == nil)
        #expect(navigation.view == .overview)
    }

    @Test("Each density has a fixed height, so switching tabs never resizes the notch")
    func density() {
        #expect(GitHubPanelDensity.compact.contentHeight < GitHubPanelDensity.expanded.contentHeight)
        #expect(GitHubPanelDensity.compact.rowLimit < GitHubPanelDensity.expanded.rowLimit)
    }
}

// MARK: - Activity

@Suite("GitHub activity")
struct GitHubActivityTests {
    @Test("Run status keeps waiting apart from queued, and maps every conclusion")
    func runStatus() {
        #expect(GitHubRunStatus.from(status: "queued", conclusion: nil) == .queued)
        #expect(GitHubRunStatus.from(status: "waiting", conclusion: nil) == .waiting)
        #expect(GitHubRunStatus.from(status: "in_progress", conclusion: nil) == .inProgress)
        #expect(GitHubRunStatus.from(status: "completed", conclusion: "success") == .success)
        #expect(GitHubRunStatus.from(status: "completed", conclusion: "timed_out") == .failure)
        #expect(GitHubRunStatus.from(status: "completed", conclusion: "cancelled") == .cancelled)
        #expect(GitHubRunStatus.from(status: "completed", conclusion: "skipped") == .skipped)
        #expect(GitHubRunStatus.from(status: "completed", conclusion: "action_required") == .waiting)
        #expect(GitHubRunStatus.from(status: "completed", conclusion: nil) == .unknown)
        #expect(GitHubRunStatus.queued.isActive && GitHubRunStatus.waiting.isActive && GitHubRunStatus.inProgress.isActive)
        #expect(!GitHubRunStatus.failure.isActive)
    }

    @Test("Elapsed time exists only for a running run that reported its start")
    func elapsed() {
        let running = run(1, status: "in_progress", conclusion: nil)
        #expect(running.elapsed(at: base.addingTimeInterval(125)) == 125)
        #expect(run(2).elapsed(at: base.addingTimeInterval(125)) == nil)
    }

    @Test("A workflow that failed and then passed is not counted as failing")
    func latestRunPerWorkflow() {
        let snapshot = GitHubRepoSnapshot(ref: api, runs: [
            run(2, conclusion: "success", minute: 10),
            run(1, conclusion: "failure", minute: 0),
            run(3, name: "Deploy", conclusion: "failure", minute: 5),
            run(4, conclusion: "failure", branch: "feature", minute: 1),
        ])
        #expect(Set(snapshot.failingRuns.map(\.id)) == [3, 4])
    }

    @Test("The overview counts what matters and lists the urgent first")
    func overview() {
        let snapshots = [
            GitHubRepoSnapshot(ref: api, pullRequests: [
                pr(1, author: "me", review: .changesRequested),
                pr(2, author: "me", mergeable: "dirty"),
                pr(3, author: "bob", review: .changesRequested),
                pr(4, author: "me", ci: .failure),
            ], runs: [run(10, conclusion: "failure"), run(11, name: "Lint", status: "in_progress", conclusion: nil)]),
            GitHubRepoSnapshot(ref: web, pullRequests: [pr(5, repository: "acme/web")]),
        ]
        let reviews = [pr(9, repository: "acme/web", author: "bob"), pr(8, repository: "elsewhere/x", author: "bob")]
        let overview = GitHubOverview.make(snapshots, reviewRequests: reviews, viewer: "ME")
        #expect(overview.openPullRequests == 5)
        #expect(overview.runningRuns == 1)
        #expect(overview.failedWorkflows == 1)
        #expect(overview.reviewsWaiting == 1, "only reviews in monitored repositories count")
        let kinds = overview.attention.map { item -> String in
            switch item {
            case .failedRun: "run"
            case .mergeConflict: "conflict"
            case .changesRequested: "changes"
            case .ciFailing: "ci"
            case .reviewRequested: "review"
            }
        }
        #expect(kinds == ["run", "conflict", "changes", "ci", "review"], "bob's PR #3 is not the viewer's to fix")
    }

    @Test("The button shows the most urgent state, honouring the owner's indicator choices")
    func indicator() {
        let failing = GitHubOverview.make([GitHubRepoSnapshot(ref: api, runs: [run(1, conclusion: "failure")])], reviewRequests: [], viewer: nil)
        let running = GitHubOverview.make([GitHubRepoSnapshot(ref: api, runs: [run(1, status: "in_progress", conclusion: nil)])], reviewRequests: [], viewer: nil)
        let review = GitHubOverview.make([GitHubRepoSnapshot(ref: api)], reviewRequests: [pr(3)], viewer: nil)
        func resolve(_ overview: GitHubOverview, connected: Bool = true, running: Bool = true, prs: Bool = true, viewed: Date? = .distantFuture) -> GitHubIndicator {
            GitHubIndicator.resolve(enabled: true, connected: connected, overview: overview, lastViewed: viewed, showRunning: running, showPullRequests: prs)
        }
        #expect(resolve(failing) == .failed)
        #expect(resolve(failing, connected: false) == .unavailable)
        #expect(resolve(running) == .running)
        #expect(resolve(running, running: false) == .idle)
        #expect(resolve(review) == .attention)
        #expect(resolve(review, prs: false) == .idle)
        #expect(resolve(running, running: false, viewed: nil) == .activity)
        #expect(GitHubIndicator.resolve(enabled: false, connected: true, overview: .empty, lastViewed: nil, showRunning: true, showPullRequests: true) == .unavailable)
        #expect(GitHubIndicator.failed.showsInClosedNotch && GitHubIndicator.attention.showsInClosedNotch)
        #expect(!GitHubIndicator.running.showsInClosedNotch && !GitHubIndicator.activity.showsInClosedNotch)
    }

    @Test("Pull request filters", arguments: GitHubPRFilter.allCases)
    func filters(_ filter: GitHubPRFilter) {
        let all = [
            pr(1), pr(2, draft: true), pr(3, review: .reviewRequired), pr(4, review: .changesRequested),
            pr(5, review: .approved, ci: .success), pr(6, ci: .failure),
            pr(7, state: "closed", merged: true), pr(8, review: .approved, ci: .success, mergeable: "dirty"),
        ]
        let expected: [GitHubPRFilter: [Int]] = [
            .all: [1, 2, 3, 4, 5, 6, 7, 8], .open: [1, 3, 4, 5, 6, 8], .draft: [2], .reviewRequested: [3],
            .changesRequested: [4], .approved: [5, 8], .ciFailing: [6], .readyToMerge: [5], .merged: [7],
        ]
        #expect(filter.apply(all).map(\.number) == expected[filter])
    }

    @Test("Merge states map from GitHub's mergeable_state")
    func mergeability() {
        #expect(GitHubMergeability.from("clean") == .ready)
        #expect(GitHubMergeability.from("dirty") == .conflicts)
        #expect(GitHubMergeability.from("blocked") == .blocked)
        #expect(GitHubMergeability.from(nil) == .unknown)
        #expect(GitHubMergeability.unknown.label == nil)
    }

    @Test("A long description is cut for the panel and says so")
    func bodyPreview() {
        let detail = GitHubPullRequestDetail(pullRequest: pr(1), body: String(repeating: "a", count: 700))
        let preview = detail.bodyPreview(limit: 600)
        #expect(preview?.truncated == true)
        #expect(preview?.text.hasSuffix("…") == true)
        #expect(GitHubPullRequestDetail(pullRequest: pr(1), body: "  ").bodyPreview() == nil)
    }

    @Test("The polling budget shrinks with more repositories and stops near the rate limit")
    func budget() {
        #expect(GitHubPollBudget.detailLimit(repositoryCount: 1, remaining: nil) == GitHubClient.detailLimit)
        #expect(GitHubPollBudget.detailLimit(repositoryCount: 20, remaining: 4000) == 2)
        #expect(GitHubPollBudget.detailLimit(repositoryCount: 5, remaining: 120) == 0)
    }
}

// MARK: - Run events

@Suite("GitHub run events")
struct GitHubRunEventTests {
    @Test("The first look never announces anything")
    func firstLook() {
        #expect(GitHubRunEventDiff.events(from: nil, to: [run(1, conclusion: "failure")]).isEmpty)
    }

    @Test("Started, failed and succeeded transitions")
    func transitions() {
        let before = [run(1, status: "in_progress", conclusion: nil), run(2, status: "queued", conclusion: nil, minute: 1)]
        let after = [run(1, conclusion: "failure"), run(2, conclusion: "success", minute: 1), run(3, status: "in_progress", conclusion: nil, minute: 2)]
        let events = GitHubRunEventDiff.events(from: before, to: after)
        #expect(events.map(\.kind) == [.githubWorkflowFailed, .githubWorkflowSucceeded, .githubWorkflowStarted])
    }

    @Test("Cancelled runs and unchanged runs are quiet")
    func quiet() {
        let before = [run(1, status: "in_progress", conclusion: nil), run(2)]
        let after = [run(1, conclusion: "cancelled"), run(2)]
        #expect(GitHubRunEventDiff.events(from: before, to: after).isEmpty)
    }

    @Test("A run that started and finished between polls still reports its result")
    func fastRun() {
        let events = GitHubRunEventDiff.events(from: [run(1, minute: 0)], to: [run(2, conclusion: "failure", minute: 3), run(1, minute: 0)])
        #expect(events.map(\.kind) == [.githubWorkflowFailed])
    }

    @Test("An old run scrolling into view is not news")
    func olderRun() {
        let events = GitHubRunEventDiff.events(from: [run(5, minute: 10)], to: [run(5, minute: 10), run(4, conclusion: "failure", minute: 2)])
        #expect(events.isEmpty)
    }

    @Test("A re-run that fails again is news again, with its own key")
    func reRun() {
        let first = GitHubRunEvent.failed(run(1, conclusion: "failure"))
        let events = GitHubRunEventDiff.events(
            from: [run(1, conclusion: "failure")],
            to: [run(1, status: "in_progress", conclusion: nil, attempt: 2)]
        )
        #expect(events.map(\.kind) == [.githubWorkflowStarted])
        let second = GitHubRunEvent.failed(run(1, conclusion: "failure", attempt: 2))
        #expect(first.dedupeKey != second.dedupeKey)
    }

    @Test("A pull request that develops a conflict produces one event")
    func mergeConflict() {
        let events = GitHubEventDiff.events(from: [pr(1, mergeable: "clean")], to: [pr(1, mergeable: "dirty")])
        #expect(events == [.mergeConflict(prID: "acme/api#1")])
        #expect(GitHubEventDiff.events(from: [pr(1, mergeable: "dirty")], to: [pr(1, mergeable: "dirty")]).isEmpty)
        #expect(GitHubEvent.mergeConflict(prID: "x").overheadKind == .githubMergeConflict)
    }
}

// MARK: - Notifications

@Suite("GitHub notifications")
struct GitHubNotificationTests {
    private func settings(_ edit: (inout OverheadSettings) -> Void = { _ in }) -> OverheadSettings {
        var settings = OverheadSettings()
        settings.github.enabled = true
        edit(&settings)
        return settings
    }

    private let noon = NotificationContext(now: base, calendar: Calendar(identifier: .gregorian))

    @Test("A failed workflow is critical: shown, but never opens the notch over Claude")
    func failedWorkflow() {
        var ledger = DeliveryLedger()
        let decision = NotificationPolicy.decide(.githubWorkflowFailed, key: "run:1", settings: settings(), context: noon, ledger: &ledger)
        #expect(decision.showInNotch)
        #expect(!decision.expandNotch)
        #expect(!decision.playSound, "GitHub starts silent until the owner turns sound on")
        // A permission request still opens it, exactly as before.
        let permission = NotificationPolicy.decide(.permissionRequested, key: "p", settings: settings(), context: noon, ledger: &ledger)
        #expect(permission.expandNotch)
    }

    @Test("A successful workflow is off by default, and quiet when turned on")
    func successfulWorkflow() {
        var ledger = DeliveryLedger()
        #expect(NotificationPolicy.decide(.githubWorkflowSucceeded, key: "run:2", settings: settings(), context: noon, ledger: &ledger) == .suppressed)
        let on = settings { $0.notifications.perEvent[.githubWorkflowSucceeded] = EventPreference(enabled: true, sound: false, systemBanner: false) }
        let decision = NotificationPolicy.decide(.githubWorkflowSucceeded, key: "run:2", settings: on, context: noon, ledger: &ledger)
        #expect(decision.showInNotch && !decision.expandNotch && !decision.playSound)
    }

    @Test("Review requests, approvals and merges are informational")
    func informational() {
        for kind in [OverheadEventKind.githubReviewRequested, .githubApproved, .githubMerged, .githubWorkflowSucceeded, .githubNewComments] {
            #expect(kind.priority == .informational, "\(kind)")
        }
        #expect(OverheadEventKind.githubWorkflowStarted.priority == .ambient)
    }

    @Test("The same failure is announced once")
    func duplicates() {
        var ledger = DeliveryLedger()
        let first = NotificationPolicy.decide(.githubWorkflowFailed, key: "run:1.1", settings: settings(), context: noon, ledger: &ledger)
        let later = NotificationContext(now: base.addingTimeInterval(120), calendar: noon.calendar)
        let again = NotificationPolicy.decide(.githubWorkflowFailed, key: "run:1.1", settings: settings(), context: later, ledger: &ledger)
        #expect(first.showInNotch)
        #expect(again == .suppressed, "GitHub keys use the 10-minute window, not Claude's 30 seconds")
    }

    @Test("Focus hides informational GitHub news when asked, but still shows failures")
    func focus() {
        let focused = settings {
            $0.focus.isOn = true
            $0.focus.suppressInformational = true
            $0.notifications.perEvent[.githubWorkflowFailed] = EventPreference(enabled: true, sound: true, systemBanner: false)
            $0.notifications.perEvent[.githubApproved] = EventPreference(enabled: true, sound: false, systemBanner: false)
        }
        var outOfFocus = focused
        outOfFocus.focus.isOn = false
        var probe = DeliveryLedger()
        #expect(NotificationPolicy.decide(.githubApproved, key: "a", settings: outOfFocus, context: noon, ledger: &probe).showInNotch,
                "approvals are on here, so only Focus can hide them")
        var ledger = DeliveryLedger()
        #expect(NotificationPolicy.decide(.githubApproved, key: "a", settings: focused, context: noon, ledger: &ledger) == .suppressed)
        let failed = NotificationPolicy.decide(.githubWorkflowFailed, key: "f", settings: focused, context: noon, ledger: &ledger)
        #expect(failed.showInNotch)
        #expect(!failed.playSound, "Focus mutes sounds by default")
    }

    @Test("Turning Actions monitoring off silences workflow events")
    func monitoringOff() {
        var ledger = DeliveryLedger()
        let off = settings { $0.github.monitorActions = false }
        #expect(NotificationPolicy.decide(.githubWorkflowFailed, key: "x", settings: off, context: noon, ledger: &ledger) == .suppressed)
        let disabled = settings { $0.github.enabled = false }
        #expect(NotificationPolicy.decide(.githubMergeConflict, key: "y", settings: disabled, context: noon, ledger: &ledger) == .suppressed)
    }

    @Test("Per-repository levels decide which kinds a repository may send")
    func repositoryLevels() {
        #expect(GitHubAlertLevel.all.allows(.githubWorkflowSucceeded))
        #expect(GitHubAlertLevel.important.allows(.githubWorkflowFailed))
        #expect(GitHubAlertLevel.important.allows(.githubReviewRequested))
        #expect(!GitHubAlertLevel.important.allows(.githubApproved))
        #expect(!GitHubAlertLevel.off.allows(.githubWorkflowFailed))
        var preferences = GitHubPreferences()
        preferences.setAlertLevel(.off, for: 101)
        #expect(preferences.alertLevel(for: 101) == .off)
        #expect(preferences.alertLevel(for: 102) == .all)
        preferences.setAlertLevel(.all, for: 101)
        #expect(preferences.repositoryAlerts.isEmpty, "the default is not stored")
    }

    @Test("A burst from one repository becomes one notice; other repositories stay separate")
    func grouping() {
        let notices = [
            GitHubNotice(kind: .githubWorkflowFailed, key: "run:1", repository: "acme/api", title: "acme/api", body: "CI failed."),
            GitHubNotice(kind: .githubWorkflowFailed, key: "run:2", repository: "acme/api", title: "acme/api", body: "Lint failed."),
            GitHubNotice(kind: .githubWorkflowFailed, key: "run:3", repository: "acme/web", title: "acme/web", body: "CI failed."),
            GitHubNotice(kind: .githubApproved, key: "a", repository: "acme/api", title: "acme/api #4", body: "Approved."),
        ]
        let grouped = GitHubNoticeGrouping.group(notices, enabled: true)
        #expect(grouped.count == 3)
        #expect(grouped[0].body == "2 workflows failed.")
        #expect(grouped[0].key == "run:1,run:2")
        #expect(GitHubNoticeGrouping.group(notices, enabled: false) == notices)
    }
}

// MARK: - Settings

@Suite("GitHub settings")
struct GitHubSettingsTests {
    @Test("Defaults: GitHub Mode and its button on, overview first, compact panel")
    func defaults() {
        let preferences = GitHubPreferences()
        #expect(preferences.notchModeEnabled && preferences.showNotchButton)
        #expect(preferences.defaultView == .overview)
        #expect(preferences.density == .compact)
        #expect(preferences.showInClosedNotch && preferences.groupNotifications && preferences.fastRefreshWhileRunning)
        #expect(preferences.selection.isEmpty && preferences.selection.followClaudeRepositories)
        #expect(!preferences.showsNotchButton, "no button while GitHub itself is off")
    }

    @Test("The button needs GitHub on, GitHub Mode on, and the button on")
    func buttonVisibility() {
        var preferences = GitHubPreferences(enabled: true)
        #expect(preferences.showsNotchButton)
        preferences.showNotchButton = false
        #expect(!preferences.showsNotchButton)
        preferences.showNotchButton = true
        preferences.notchModeEnabled = false
        #expect(!preferences.showsNotchButton)
    }

    @Test("Settings from before GitHub Mode keep their values and gain the new defaults")
    func legacyDecoding() throws {
        let json = #"{"enabled": true, "monitorActions": false, "refreshMinutes": 10}"#
        let decoded = try JSONDecoder().decode(GitHubPreferences.self, from: Data(json.utf8))
        #expect(decoded.enabled && !decoded.monitorActions && decoded.refreshMinutes == 10)
        #expect(decoded.notchModeEnabled && decoded.defaultView == .overview)
        #expect(decoded.selection.isEmpty)
    }

    @Test("Unknown values fall back one field at a time")
    func lenient() throws {
        let json = """
        {"enabled": true, "defaultView": "sideways", "density": "expanded",
         "repositoryAlerts": {"101": "off", "102": "loud"}, "lastView": "actions"}
        """
        let decoded = try JSONDecoder().decode(GitHubPreferences.self, from: Data(json.utf8))
        #expect(decoded.defaultView == .overview)
        #expect(decoded.density == .expanded)
        #expect(decoded.lastView == .actions)
        #expect(decoded.repositoryAlerts == ["101": .off])
    }

    @Test("Every GitHub Mode preference survives a restart")
    func persistence() throws {
        try withIsolatedDefaults { defaults in
            var settings = OverheadSettings()
            settings.github = GitHubPreferences(
                enabled: true, refreshMinutes: 15,
                selection: GitHubRepositorySelection(repositories: [api, tools], focusedID: 103),
                showNotchButton: false, showAccount: false, showRunningIndicator: false,
                defaultView: .lastActive, lastView: .pullRequests, density: .expanded,
                showDetailedMetadata: false, groupNotifications: false, fastRefreshWhileRunning: false,
                repositoryAlerts: ["103": .important]
            )
            SettingsStore(defaults: defaults).save(settings)
            #expect(SettingsStore(defaults: defaults).load().github == settings.github)
        }
    }

    @Test("GitHub Mode has its own shortcut, ⌃⌥G, clashing with nothing")
    func shortcut() {
        #expect(ShortcutDefaults.bindings[.toggleGitHubMode]?.keyCode == VirtualKey.g)
        #expect(ShortcutAction.toggleGitHubMode.displayName == "Toggle GitHub Mode")
    }

    @Test("Settings saved before ⌃⌥G existed gain it, while a shortcut the owner cleared stays cleared")
    func shortcutMigration() throws {
        var older = OverheadSettings()
        older.shortcuts[.toggleGitHubMode] = nil
        older.shortcuts[.openHistory] = nil
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(older)) as? [String: Any])
        var shortcuts = try #require(json["shortcuts"] as? [String: Any])
        shortcuts.removeValue(forKey: ShortcutAction.toggleGitHubMode.rawValue)
        shortcuts[ShortcutAction.openHistory.rawValue] = NSNull()
        json["shortcuts"] = shortcuts
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.shortcuts[.toggleGitHubMode] == ShortcutDefaults.bindings[.toggleGitHubMode])
        #expect(decoded.shortcuts[.openHistory] == nil)
    }
}
