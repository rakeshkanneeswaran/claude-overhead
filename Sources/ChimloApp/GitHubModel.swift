import AppKit
import ChimloCore
import Foundation

/// GitHub for the repositories the owner chose. One instance feeds GitHub
/// Mode in the notch, the companion window and notifications, so all three
/// always show the same data.
///
/// Sign-in reuses the GitHub CLI (`gh auth token`) and falls back to a
/// personal access token in the Keychain; the token is never written to
/// preferences, logs or the UI. Requests go only to api.github.com, only while
/// GitHub is on, and never block the main thread or Claude's session work.
@MainActor
final class GitHubModel: ObservableObject {
    enum Connection: Equatable {
        case off
        case checking
        /// No usable credential. Carries what the GitHub CLI reported.
        case signedOut(GitHubCLIStatus)
        case connected(login: String, source: GitHubCredential.Source)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    enum Load<Value: Equatable>: Equatable {
        case loading
        case loaded(Value, at: Date)
        case failed(String)

        var value: Value? {
            if case let .loaded(value, _) = self { return value }
            return nil
        }
    }

    @Published private(set) var connection: Connection = .off
    /// One snapshot per monitored repository, in selection order.
    @Published private(set) var snapshots: [GitHubRepoSnapshot] = []
    @Published private(set) var reviewRequests: [GitHubPullRequest] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var rateLimit: GitHubRateLimit?
    @Published private(set) var isRefreshing = false
    /// Counts for today's recap, from events seen while Overhead ran.
    @Published private(set) var todayCounts = RecapGitHubInput()
    /// Project folders skipped because they are in a protected folder the
    /// owner has not let Overhead into yet.
    @Published private(set) var foldersAwaitingAccess: [String] = []
    /// Repositories Claude works in, resolved to GitHub identities.
    @Published private(set) var claudeRepositories: [GitHubRepoRef] = []
    /// Everything the viewer can read, for the repository picker. Loaded only
    /// when the picker asks.
    @Published private(set) var availableRepositories: Load<[GitHubRepoRef]>?
    @Published private(set) var jobs: [Int: Load<[GitHubWorkflowJob]>] = [:]
    @Published private(set) var pullRequestDetails: [String: Load<GitHubPullRequestDetail>] = [:]
    /// When the owner last looked at GitHub Mode, for the "new activity" dot.
    @Published private(set) var lastViewed: Date?
    /// A detail the notch asked the companion window to show.
    @Published var companionRequest: GitHubDetail?

    /// GitHub changes worth announcing, already mapped to Overhead events.
    var onEvent: ((AttentionEvent) -> Void)?
    /// Project folders to look for repositories in.
    var projectPaths: () -> [String] = { [] }
    /// Saves a changed selection (new Claude repositories, a rename, a new
    /// focus). Settings own the selection; this model never keeps its own copy.
    var saveSelection: ((GitHubRepositorySelection) -> Void)?

    private let tokenStore = KeychainTokenStore()
    private let gitReader = GitRepositoryReader()
    private let folderAccess: FolderAccessModel
    private var client: GitHubClient?
    private var preferences = GitHubPreferences()
    private var pollTask: Task<Void, Never>?
    private var repositoryInfo: [String: GitRepositoryInfo?] = [:]
    /// "owner/name" (lowercased) → GitHub identity, so a remote is resolved once.
    private var resolvedRemotes: [String: GitHubRepoRef] = [:]
    /// Local folders per repository, for matching sessions to pull requests.
    private var localPaths: [Int64: [String]] = [:]
    private var defaultBranches: [Int64: String] = [:]
    private var pullRequestBaseline: Set<Int64> = []
    private var runBaseline: Set<Int64> = []
    private var hasReviewBaseline = false
    private var countsDay = Calendar.current.startOfDay(for: .now)
    private var nextFullRefresh = Date.distantPast
    private var pendingFullRefresh = false

    init(folderAccess: FolderAccessModel) {
        self.folderAccess = folderAccess
    }

    var viewerLogin: String? {
        if case let .connected(login, _) = connection { return login }
        return nil
    }

    var isEnabled: Bool { preferences.enabled }
    var selection: GitHubRepositorySelection { preferences.selection }
    var focusedSnapshot: GitHubRepoSnapshot? {
        guard let id = preferences.selection.focusedID else { return snapshots.first }
        return snapshots.first { $0.id == id } ?? snapshots.first
    }

    func snapshot(_ id: Int64) -> GitHubRepoSnapshot? { snapshots.first { $0.id == id } }

    /// The overview over every monitored repository.
    var overview: GitHubOverview {
        GitHubOverview.make(snapshots, reviewRequests: reviewRequests, viewer: viewerLogin)
    }

    var indicator: GitHubIndicator {
        GitHubIndicator.resolve(
            enabled: preferences.enabled,
            connected: connection.isConnected,
            overview: overview,
            lastViewed: lastViewed,
            showRunning: preferences.showRunningIndicator,
            showPullRequests: preferences.showPullRequestIndicator
        )
    }

    // MARK: Preferences

    func apply(_ preferences: GitHubPreferences) {
        let previous = self.preferences
        self.preferences = preferences
        if !preferences.enabled {
            stop()
            connection = .off
            snapshots = []
            reviewRequests = []
            jobs = [:]
            pullRequestDetails = [:]
            pullRequestBaseline = []
            runBaseline = []
            hasReviewBaseline = false
            return
        }
        let added = reconcileSnapshots()
        let needsFreshLook = previous.refreshMinutes != preferences.refreshMinutes
            || previous.trackPullRequests != preferences.trackPullRequests
            || previous.monitorActions != preferences.monitorActions
            || !added.isEmpty
        if !previous.enabled || pollTask == nil {
            startPolling()
        } else if needsFreshLook {
            // Never cancel a refresh halfway: a new repository added during
            // one (Claude's, or a rename) waits for it to finish, then gets
            // a full pass straight away.
            if isRefreshing {
                pendingFullRefresh = true
            } else {
                nextFullRefresh = .distantPast
                startPolling()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        guard preferences.enabled else { return }
        nextFullRefresh = .distantPast
        startPolling()
    }

    /// Marks GitHub Mode as seen, which clears the "new activity" state.
    func markViewed() {
        lastViewed = .now
    }

    func focus(_ id: Int64) {
        var selection = preferences.selection
        guard selection.contains(id), selection.focusedID != id else { return }
        selection.focus(id)
        saveSelection?(selection)
    }

    // MARK: Sign-in

    /// Stores a personal access token in the Keychain and reconnects.
    func savePersonalAccessToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try tokenStore.save(trimmed)
        client = nil
        refreshNow()
    }

    func removePersonalAccessToken() throws {
        try tokenStore.delete()
        client = nil
        refreshNow()
    }

    var hasStoredToken: Bool {
        ((try? tokenStore.read()) ?? nil) != nil
    }

    /// Forgets the sign-in Overhead holds: the Keychain token, if any, and the
    /// in-memory client. The GitHub CLI's own login is the CLI's to manage.
    func disconnect() {
        try? tokenStore.delete()
        client = nil
        stop()
        connection = .off
        snapshots = []
        reviewRequests = []
    }

    // MARK: Lookups for the UI

    /// The pull request a session is working on: one Claude linked, else the
    /// open PR for its branch.
    func pullRequest(for session: SessionDisplayModel) -> GitHubPullRequest? {
        guard let path = session.projectPath,
              let id = localPaths.first(where: { _, paths in
                  paths.contains { path == $0 || path.hasPrefix($0 + "/") }
              })?.key,
              let snapshot = snapshot(id) else { return nil }
        return GitHubMatching.pullRequest(
            forBranch: session.insights?.gitBranch,
            repository: snapshot.ref.fullName,
            in: snapshot.pullRequests,
            linkedNumbers: session.insights?.pullRequests.map(\.number) ?? [],
            defaultBranch: snapshot.defaultBranch
        )
    }

    func run(_ runID: Int, in repositoryID: Int64) -> GitHubWorkflowRun? {
        snapshot(repositoryID)?.runs.first { $0.id == runID }
    }

    func pullRequest(_ number: Int, in repositoryID: Int64) -> GitHubPullRequest? {
        snapshot(repositoryID)?.allPullRequests.first { $0.number == number }
            ?? reviewRequests.first { $0.number == number && $0.repository.lowercased() == snapshot(repositoryID)?.ref.fullName.lowercased() }
    }

    /// A review request's repository among the monitored ones, if any.
    func repositoryID(named fullName: String) -> Int64? {
        snapshots.first { $0.ref.fullName.lowercased() == fullName.lowercased() }?.id
    }

    /// Opens a GitHub page, but only an https URL on github.com: PR and run
    /// URLs come from the API and are never trusted blindly.
    static func openWebPage(_ string: String?) {
        guard let string, let url = URL(string: string),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: On-demand detail

    func loadAvailableRepositories(force: Bool = false) {
        if !force, case let .loaded(_, at)? = availableRepositories, at.timeIntervalSinceNow > -600 { return }
        if case .loading? = availableRepositories { return }
        guard let client else {
            availableRepositories = .failed(connection.isConnected ? "Not ready yet." : "Connect GitHub to list your repositories.")
            return
        }
        availableRepositories = .loading
        Task {
            do {
                let repositories = try await client.viewerRepositories().map(\.ref)
                availableRepositories = .loaded(repositories, at: .now)
                // Renames show up here first; carry them into the selection.
                var selection = preferences.selection
                var changed = false
                for repository in repositories where selection.contains(repository.id) {
                    let before = selection
                    selection.refresh(repository)
                    changed = changed || before != selection
                }
                if changed { saveSelection?(selection) }
            } catch {
                availableRepositories = .failed(Self.describe(error))
            }
        }
    }

    func loadJobs(runID: Int, repositoryID: Int64, force: Bool = false) {
        guard let client, let snapshot = snapshot(repositoryID) else { return }
        if !force, let existing = jobs[runID] {
            switch existing {
            case .loading: return
            case let .loaded(_, at) where at.timeIntervalSinceNow > -30: return
            default: break
            }
        }
        if jobs[runID] == nil { jobs[runID] = .loading }
        let remote = snapshot.ref.remote
        Task {
            do {
                jobs[runID] = .loaded(try await client.workflowJobs(remote, runID: runID), at: .now)
            } catch {
                jobs[runID] = .failed(Self.describe(error))
            }
        }
    }

    func loadPullRequestDetail(number: Int, repositoryID: Int64, force: Bool = false) {
        guard let client, let snapshot = snapshot(repositoryID) else { return }
        let key = "\(repositoryID)#\(number)"
        if !force, let existing = pullRequestDetails[key] {
            switch existing {
            case .loading: return
            case let .loaded(_, at) where at.timeIntervalSinceNow > -60: return
            default: break
            }
        }
        if pullRequestDetails[key] == nil { pullRequestDetails[key] = .loading }
        let remote = snapshot.ref.remote
        Task {
            do {
                pullRequestDetails[key] = .loaded(try await client.pullRequestDetail(remote, number: number), at: .now)
            } catch {
                pullRequestDetails[key] = .failed(Self.describe(error))
            }
        }
    }

    func pullRequestDetail(number: Int, repositoryID: Int64) -> Load<GitHubPullRequestDetail>? {
        pullRequestDetails["\(repositoryID)#\(number)"]
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await refresh()
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// One refresh: a full one when due, otherwise a quick look at the
    /// repositories with running workflows. Returns how long to wait.
    private func refresh() async -> TimeInterval {
        let fullInterval = TimeInterval(max(GitHubPreferences.refreshRange.lowerBound, preferences.refreshMinutes) * 60)
        isRefreshing = true
        defer { isRefreshing = false }
        rollCountsIfNeeded()

        if client == nil {
            connection = .checking
            guard let credential = await GitHubCredentialResolver(tokenStore: tokenStore).resolve() else {
                connection = .signedOut(await GitHubCLI().status())
                return fullInterval
            }
            let candidate = GitHubClient(credential: credential, transport: GitHubNetwork.transport)
            do {
                let login = try await candidate.viewerLogin()
                client = candidate
                connection = .connected(login: login, source: credential.source)
            } catch {
                return handle(error) ?? fullInterval
            }
        }
        guard let client else { return fullInterval }

        let full = Date.now >= nextFullRefresh
        var notices: [GitHubNotice] = []
        do {
            if full {
                await discoverRepositories(client: client)
            }
            reconcileSnapshots()
            let limit = GitHubPollBudget.detailLimit(repositoryCount: snapshots.count, remaining: client.lastRateLimit?.remaining)
            // The focused repository first: it is the one on screen.
            let focusedID = preferences.selection.focusedID
            let order = snapshots.map(\.id).filter { $0 == focusedID } + snapshots.map(\.id).filter { $0 != focusedID }
            if full {
                // Repositories seen for the first time get a quick look first,
                // all at once, so every row has data within seconds; reviews
                // and checks follow in the full pass.
                let fresh = order.filter { !runBaseline.contains($0) && !pullRequestBaseline.contains($0) }
                if !fresh.isEmpty { await quickLook(fresh, client: client) }
            }
            for id in order {
                try Task.checkCancellation()
                guard let snapshot = snapshot(id) else { continue }
                if !full, snapshot.activeRuns.isEmpty { continue }
                notices += try await refresh(id, client: client, full: full, detailLimit: limit)
            }
            if full {
                notices += try await refreshReviewRequests(client: client)
            }
        } catch {
            if let pause = handle(error) { return pause }
        }
        // A cancelled refresh leaves the schedule alone; the new one decides.
        if Task.isCancelled { return 0 }
        deliver(notices)
        rateLimit = client.lastRateLimit
        lastRefresh = .now
        if full { nextFullRefresh = Date.now.addingTimeInterval(fullInterval) }
        // What was already there at launch is not "new activity"; only what
        // changes after the first look is.
        if lastViewed == nil, full { lastViewed = .now }
        if pendingFullRefresh {
            pendingFullRefresh = false
            nextFullRefresh = .distantPast
            return 1
        }

        let hasActive = snapshots.contains { !$0.activeRuns.isEmpty }
        if hasActive, preferences.fastRefreshWhileRunning, preferences.monitorActions {
            return min(GitHubPollBudget.activeRunInterval, max(5, nextFullRefresh.timeIntervalSinceNow))
        }
        return max(5, nextFullRefresh.timeIntervalSinceNow)
    }

    private func refresh(_ id: Int64, client: GitHubClient, full: Bool, detailLimit: Int) async throws -> [GitHubNotice] {
        guard var snapshot = snapshot(id) else { return [] }
        let remote = snapshot.ref.remote
        var notices: [GitHubNotice] = []
        do {
            // Runs first: one request, and usually what the owner is after.
            if preferences.monitorActions {
                let runs = try await client.workflowRuns(remote, limit: 15)
                let events = GitHubRunEventDiff.events(from: runBaseline.contains(id) ? snapshot.runs : nil, to: runs)
                notices += events.map { notice(for: $0, repository: snapshot.ref) }
                snapshot.runs = runs
                runBaseline.insert(id)
            } else {
                snapshot.runs = []
                runBaseline.remove(id)
            }
            snapshot.availability = .available
            snapshot.lastUpdated = snapshot.lastUpdated ?? .now
            store(snapshot)
            if full, preferences.trackPullRequests {
                var open = try await client.openPullRequests(remote, detailLimit: detailLimit)
                let closed = (try? await client.recentlyClosedPullRequests(remote, limit: 8)) ?? snapshot.recentlyClosed
                // The viewer's own PRs also get GitHub's merge state, so a
                // conflict on them can be reported.
                if detailLimit > 0, let viewer = viewerLogin?.lowercased() {
                    let mine = open.indices.filter { open[$0].author?.lowercased() == viewer }.prefix(3)
                    for index in mine {
                        if let detailed = try? await client.pullRequest(remote, number: open[index].number) {
                            open[index].mergeableState = detailed.mergeableState
                        }
                    }
                }
                if pullRequestBaseline.contains(id) {
                    let before = snapshot.allPullRequests
                    var after = open + closed
                    // A PR that left the open list but is not in the closed
                    // page yet: fetch it so its merge or close is not missed.
                    let missing = before.filter { old in old.isOpen && !after.contains { $0.id == old.id } }
                    for pr in missing.prefix(3) {
                        if let latest = try? await client.pullRequest(remote, number: pr.number) { after.append(latest) }
                    }
                    for event in GitHubEventDiff.events(from: before, to: after) {
                        if let notice = notice(for: event, in: after, repository: snapshot.ref) { notices.append(notice) }
                    }
                }
                open.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                snapshot.pullRequests = open
                snapshot.recentlyClosed = closed
                pullRequestBaseline.insert(id)
            } else if !preferences.trackPullRequests {
                snapshot.pullRequests = []
                snapshot.recentlyClosed = []
                pullRequestBaseline.remove(id)
            }
            snapshot.lastUpdated = .now
            snapshot.defaultBranch = snapshot.defaultBranch ?? defaultBranches[id]
        } catch let error as GitHubError {
            switch error {
            case .unauthorized, .rateLimited:
                throw error
            case .notFound:
                snapshot.availability = await resolveMissing(snapshot.ref, client: client)
            case let .forbidden(message):
                snapshot.availability = .forbidden(message)
            default:
                snapshot.availability = .failed(error.localizedDescription)
            }
        }
        store(snapshot)
        return notices
    }

    /// Runs and the open-PR list (without reviews or checks) for several
    /// repositories at once. Only fills in what is missing: events and
    /// baselines are left to the full pass, so nothing is announced from here.
    private func quickLook(_ ids: [Int64], client: GitHubClient) async {
        // Each task runs on the main actor but waits on the network
        // concurrently, so four repositories take about as long as one.
        let looks = ids.map { id in Task { [weak self] in await self?.quickLook(id, client: client) } }
        for look in looks { await look.value }
    }

    private func quickLook(_ id: Int64, client: GitHubClient) async {
        guard let remote = snapshot(id)?.ref.remote else { return }
        let runs = preferences.monitorActions ? try? await client.workflowRuns(remote, limit: 15) : nil
        let pulls = preferences.trackPullRequests ? try? await client.openPullRequests(remote, detailLimit: 0) : nil
        guard runs != nil || pulls != nil, var snapshot = snapshot(id) else { return }
        if let runs, !runBaseline.contains(id) { snapshot.runs = runs }
        if let pulls, !pullRequestBaseline.contains(id) {
            snapshot.pullRequests = pulls.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
        snapshot.availability = .available
        snapshot.lastUpdated = snapshot.lastUpdated ?? .now
        store(snapshot)
    }

    private func store(_ snapshot: GitHubRepoSnapshot) {
        if let index = snapshots.firstIndex(where: { $0.id == snapshot.id }), snapshots[index] != snapshot {
            snapshots[index] = snapshot
        }
    }

    /// True until any monitored repository has answered once. Until then the
    /// UI says it is loading rather than showing zeros as if they were real.
    var isAwaitingFirstData: Bool {
        !snapshots.isEmpty && snapshots.allSatisfy { $0.lastUpdated == nil && $0.availability == .unknown }
    }

    /// A repository answered 404. It may have been renamed or transferred:
    /// ask for it by id, and if GitHub still knows it, follow it.
    private func resolveMissing(_ ref: GitHubRepoRef, client: GitHubClient) async -> GitHubRepoAvailability {
        guard let info = try? await client.repository(id: ref.id) else { return .notFound }
        if info.ref.fullName != ref.fullName {
            var selection = preferences.selection
            selection.refresh(info.ref)
            saveSelection?(selection)
            return .unknown
        }
        return .notFound
    }

    private func refreshReviewRequests(client: GitHubClient) async throws -> [GitHubNotice] {
        guard preferences.trackPullRequests, preferences.reviewNotifications else {
            reviewRequests = []
            hasReviewBaseline = false
            return []
        }
        let requests = try await client.reviewRequestsForViewer()
        let events = GitHubEventDiff.reviewRequests(from: hasReviewBaseline ? reviewRequests : nil, to: requests)
        hasReviewBaseline = true
        reviewRequests = requests
        return events.compactMap { event in
            guard let pr = requests.first(where: { $0.id == event.prID }) else { return nil }
            let ref = snapshots.first { $0.ref.fullName.lowercased() == pr.repository.lowercased() }?.ref
            return notice(for: event, in: requests, repository: ref, repositoryName: pr.repository)
        }
    }

    /// Keeps `snapshots` in the selection's order, adding new repositories and
    /// dropping removed ones at once, without waiting for the next refresh.
    @discardableResult
    private func reconcileSnapshots() -> [GitHubRepoRef] {
        let existing = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [GitHubRepoRef] = []
        let next = preferences.selection.repositories.map { ref -> GitHubRepoSnapshot in
            if var snapshot = existing[ref.id] {
                snapshot.ref = ref
                return snapshot
            }
            added.append(ref)
            return GitHubRepoSnapshot(ref: ref, defaultBranch: defaultBranches[ref.id])
        }
        let kept = Set(next.map(\.id))
        pullRequestBaseline.formIntersection(kept)
        runBaseline.formIntersection(kept)
        if next != snapshots { snapshots = next }
        return added
    }

    // MARK: Repositories Claude works in

    private func discoverRepositories(client: GitHubClient) async {
        var seenPaths = Set<String>()
        var awaiting: [String] = []
        var found: [GitHubRepoRef] = []
        var paths: [Int64: [String]] = [:]
        for path in projectPaths() where seenPaths.insert(path).inserted {
            let info: GitRepositoryInfo?
            if let cached = repositoryInfo[path] {
                info = cached
            } else if folderAccess.needsConfirmation(for: path) {
                // Reading git here would make macOS prompt mid-poll; wait for
                // the owner to ask (`readProtectedFolders`).
                awaiting.append(path)
                continue
            } else {
                info = await gitReader.info(for: path)
                repositoryInfo[path] = info
            }
            guard let info, let remote = info.gitHubRemote, remote.host == "github.com" else { continue }
            let key = remote.fullName.lowercased()
            var ref = resolvedRemotes[key]
            if ref == nil, let resolved = try? await client.repository(remote) {
                ref = resolved.ref
                resolvedRemotes[key] = resolved.ref
                if let branch = resolved.defaultBranch { defaultBranches[resolved.ref.id] = branch }
            }
            guard let ref else { continue }
            if let branch = info.defaultBranch, defaultBranches[ref.id] == nil { defaultBranches[ref.id] = branch }
            if !found.contains(where: { $0.id == ref.id }) { found.append(ref) }
            paths[ref.id, default: []].append(info.root)
        }
        localPaths = paths
        if found != claudeRepositories { claudeRepositories = found }
        if awaiting != foldersAwaitingAccess { foldersAwaitingAccess = awaiting }
        var selection = preferences.selection
        if !selection.adoptClaudeRepositories(found).isEmpty {
            saveSelection?(selection)
        }
    }

    /// Reads git remotes in protected folders after the owner asked to;
    /// macOS may show its folder prompt now, once per folder.
    func readProtectedFolders() {
        let paths = foldersAwaitingAccess
        guard !paths.isEmpty else { return }
        let reader = GitRepositoryReader(timeout: FolderAccessModel.promptTimeout)
        Task {
            for path in paths {
                let info = await reader.info(for: path)
                repositoryInfo[path] = info
                if info != nil { folderAccess.recordSuccess(for: path) }
            }
            refreshNow()
        }
    }

    // MARK: Errors

    private func handle(_ error: any Error) -> TimeInterval? {
        guard let error = error as? GitHubError else {
            if error is CancellationError { return nil }
            if !connection.isConnected { connection = .failed(error.localizedDescription) }
            return nil
        }
        switch error {
        case .unauthorized:
            client = nil
            connection = .failed("GitHub rejected the sign-in. Run `gh auth login` again or save a new token.")
            return nil
        case let .rateLimited(resetAt):
            let wait = max(60, (resetAt ?? .now.addingTimeInterval(300)).timeIntervalSinceNow)
            connection = connection.isConnected ? connection : .failed("GitHub rate limit reached.")
            return wait
        default:
            if !connection.isConnected { connection = .failed(error.localizedDescription) }
            return nil
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? GitHubError)?.localizedDescription ?? error.localizedDescription
    }

    // MARK: Events

    private func notice(for event: GitHubRunEvent, repository: GitHubRepoRef) -> GitHubNotice {
        let run = event.run
        let branch = run.branch.map { " on \($0)" } ?? ""
        let body: String
        switch event {
        case .started: body = "\(run.name) started\(branch)."
        case .failed:
            body = "\(run.name) failed\(branch)."
            todayCounts.ciFailures += 1
        case .succeeded:
            body = "\(run.name) succeeded\(branch)."
            todayCounts.ciSuccesses += 1
        }
        return GitHubNotice(kind: event.kind, key: event.dedupeKey, repository: repository.fullName, title: repository.fullName, body: body)
    }

    private func notice(
        for event: GitHubEvent,
        in prs: [GitHubPullRequest],
        repository: GitHubRepoRef?,
        repositoryName: String? = nil
    ) -> GitHubNotice? {
        guard let pr = prs.first(where: { $0.id == event.prID }), let kind = event.overheadKind else { return nil }
        let body: String
        switch event {
        case .reviewRequested:
            body = "Your review was requested."
            todayCounts.reviewsWaiting += 1
        case .changesRequested: body = "Changes were requested."
        case .approved: body = "Approved."
        case let .newComments(_, count): body = count == 1 ? "1 new comment." : "\(count) new comments."
        case .ciFailed: body = "Checks failed."
        case .ciPassed: body = "Checks passed."
        case .merged:
            body = "Merged."
            todayCounts.pullRequestsMerged += 1
        case .mergeConflict: body = "Has merge conflicts."
        case .closed: return nil
        }
        let name = repository?.fullName ?? repositoryName ?? pr.repository
        return GitHubNotice(kind: kind, key: event.dedupeKey, repository: name, title: "\(name) #\(pr.number)", body: "\(body) \(pr.title)")
    }

    /// Applies each repository's alert level, groups bursts, then hands the
    /// rest to the shared notification policy.
    private func deliver(_ notices: [GitHubNotice]) {
        let allowed = notices.filter { notice in
            guard let id = snapshots.first(where: { $0.ref.fullName.lowercased() == notice.repository.lowercased() })?.id else {
                // Review requests in repositories that are not monitored still
                // count: they ask something of the owner.
                return notice.kind == .githubReviewRequested
            }
            return preferences.alertLevel(for: id).allows(notice.kind)
        }
        for notice in GitHubNoticeGrouping.group(allowed, enabled: preferences.groupNotifications) {
            onEvent?(AttentionEvent(kind: notice.kind, key: notice.key, sessionID: nil, title: notice.title, body: notice.body))
        }
    }

    private func rollCountsIfNeeded() {
        let today = Calendar.current.startOfDay(for: .now)
        if today != countsDay {
            countsDay = today
            todayCounts = RecapGitHubInput()
        }
    }
}
