import AppKit
import ChimloCore
import Foundation

/// GitHub for the repositories Claude works in. Sign-in reuses the GitHub
/// CLI (`gh auth token`) and falls back to a personal access token in the
/// Keychain; the token is never written to preferences or logs. Requests go
/// only to api.github.com, only while the owner has GitHub turned on, and
/// only for repositories discovered from Claude sessions on this Mac.
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

    struct Repository: Identifiable, Equatable {
        var id: String { remote.fullName }
        let remote: GitRemote
        var localPaths: [String]
        var defaultBranch: String?
        var pullRequests: [GitHubPullRequest] = []
        var runs: [GitHubWorkflowRun] = []
        var problem: String?
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var reviewRequests: [GitHubPullRequest] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var rateLimit: GitHubRateLimit?
    @Published private(set) var isRefreshing = false
    /// Counts for today's recap, from events seen while Overhead ran.
    @Published private(set) var todayCounts = RecapGitHubInput()

    /// GitHub changes worth announcing, already mapped to Overhead events.
    var onEvent: ((AttentionEvent) -> Void)?
    /// Project folders to look for repositories in.
    var projectPaths: () -> [String] = { [] }

    private let tokenStore = KeychainTokenStore()
    private let gitReader = GitRepositoryReader()
    private var client: GitHubClient?
    private var preferences = GitHubPreferences()
    private var pollTask: Task<Void, Never>?
    private var repositoryInfo: [String: GitRepositoryInfo?] = [:]
    private var hasSnapshot: Set<String> = []
    private var countsDay = Calendar.current.startOfDay(for: .now)

    var viewerLogin: String? {
        if case let .connected(login, _) = connection { return login }
        return nil
    }

    func apply(_ preferences: GitHubPreferences) {
        let wasEnabled = self.preferences.enabled
        let intervalChanged = self.preferences.refreshMinutes != preferences.refreshMinutes
        self.preferences = preferences
        if !preferences.enabled {
            stop()
            connection = .off
            return
        }
        if !wasEnabled || pollTask == nil || intervalChanged {
            startPolling()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        guard preferences.enabled else { return }
        startPolling()
    }

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

    /// The pull request a session is working on: one Claude linked, else the
    /// open PR for its branch.
    func pullRequest(for session: SessionDisplayModel) -> GitHubPullRequest? {
        guard let path = session.projectPath,
              let repository = repositories.first(where: { repo in
                  repo.localPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
              }) else { return nil }
        return GitHubMatching.pullRequest(
            forBranch: session.insights?.gitBranch,
            repository: repository.remote.fullName,
            in: repository.pullRequests,
            linkedNumbers: session.insights?.pullRequests.map(\.number) ?? [],
            defaultBranch: repository.defaultBranch
        )
    }

    /// Opens a GitHub page, but only an https URL on github.com: PR and run
    /// URLs come from the API and are never trusted blindly.
    static func openWebPage(_ string: String) {
        guard let url = URL(string: string),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        let minutes = max(GitHubPreferences.refreshRange.lowerBound, preferences.refreshMinutes)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await refresh()
                try? await Task.sleep(for: .seconds(pause ?? Double(minutes * 60)))
            }
        }
    }

    /// One refresh. Returns a custom pause when GitHub asked to wait.
    private func refresh() async -> TimeInterval? {
        isRefreshing = true
        defer { isRefreshing = false }
        rollCountsIfNeeded()

        if client == nil {
            connection = .checking
            guard let credential = await GitHubCredentialResolver(tokenStore: tokenStore).resolve() else {
                connection = .signedOut(await GitHubCLI().status())
                return nil
            }
            let candidate = GitHubClient(credential: credential)
            do {
                let login = try await candidate.viewerLogin()
                client = candidate
                connection = .connected(login: login, source: credential.source)
            } catch let error as GitHubError {
                return handle(error)
            } catch {
                connection = .failed(error.localizedDescription)
                return nil
            }
        }
        guard let client else { return nil }

        await discoverRepositories()
        do {
            for index in repositories.indices {
                try Task.checkCancellation()
                try await refresh(repositoryAt: index, client: client)
            }
            if preferences.trackPullRequests, preferences.reviewNotifications {
                let requests = try await client.reviewRequestsForViewer()
                let previous = hasSnapshot.contains("reviews") ? reviewRequests : nil
                for event in GitHubEventDiff.reviewRequests(from: previous, to: requests) {
                    emit(event, in: requests)
                }
                hasSnapshot.insert("reviews")
                reviewRequests = requests
            } else {
                reviewRequests = []
            }
        } catch let error as GitHubError {
            return handle(error)
        } catch {
            return nil
        }
        rateLimit = client.lastRateLimit
        lastRefresh = .now
        return nil
    }

    private func refresh(repositoryAt index: Int, client: GitHubClient) async throws {
        var repository = repositories[index]
        let remote = repository.remote
        do {
            if preferences.trackPullRequests {
                var open = try await client.openPullRequests(remote)
                let previous = repository.pullRequests
                if hasSnapshot.contains(repository.id) {
                    // A PR that left the open list was merged or closed; fetch
                    // it so the diff can say which.
                    let gone = previous.filter { old in old.isOpen && !open.contains { $0.id == old.id } }
                    var finished: [GitHubPullRequest] = []
                    for pr in gone.prefix(5) {
                        if let latest = try? await client.pullRequest(remote, number: pr.number) {
                            finished.append(latest)
                        }
                    }
                    for event in GitHubEventDiff.events(from: previous, to: open + finished) {
                        emit(event, in: open + finished)
                    }
                }
                open.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                repository.pullRequests = open
            } else {
                repository.pullRequests = []
            }
            if preferences.monitorActions {
                repository.runs = try await client.workflowRuns(remote, limit: 10)
            } else {
                repository.runs = []
            }
            repository.problem = nil
            hasSnapshot.insert(repository.id)
        } catch let error as GitHubError {
            switch error {
            case .unauthorized, .rateLimited: throw error
            default: repository.problem = error.localizedDescription
            }
        }
        if index < repositories.count, repositories[index].id == repository.id {
            repositories[index] = repository
        }
    }

    private func discoverRepositories() async {
        var byName: [String: Repository] = [:]
        for repository in repositories { byName[repository.id] = repository }
        var seenPaths = Set<String>()
        for path in projectPaths() where seenPaths.insert(path).inserted {
            let info: GitRepositoryInfo?
            if let cached = repositoryInfo[path] {
                info = cached
            } else {
                info = await gitReader.info(for: path)
                repositoryInfo[path] = info
            }
            guard let info, let remote = info.gitHubRemote, remote.host == "github.com" else { continue }
            if var existing = byName[remote.fullName] {
                if !existing.localPaths.contains(info.root) { existing.localPaths.append(info.root) }
                existing.defaultBranch = existing.defaultBranch ?? info.defaultBranch
                byName[remote.fullName] = existing
            } else {
                byName[remote.fullName] = Repository(
                    remote: remote,
                    localPaths: [info.root],
                    defaultBranch: info.defaultBranch
                )
            }
        }
        let sorted = byName.values.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        if sorted != repositories { repositories = sorted }
    }

    private func handle(_ error: GitHubError) -> TimeInterval? {
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

    // MARK: Events

    private func emit(_ event: GitHubEvent, in prs: [GitHubPullRequest]) {
        guard let pr = prs.first(where: { $0.id == event.prID }) else { return }
        let kind: OverheadEventKind
        let body: String
        switch event {
        case .reviewRequested:
            kind = .githubReviewRequested; body = "Your review was requested."
            todayCounts.reviewsWaiting += 1
        case .changesRequested:
            kind = .githubChangesRequested; body = "Changes were requested."
        case .approved:
            kind = .githubApproved; body = "The pull request was approved."
        case let .newComments(_, count):
            kind = .githubNewComments; body = count == 1 ? "1 new comment." : "\(count) new comments."
        case .ciFailed:
            kind = .githubCIFailed; body = "CI failed."
            todayCounts.ciFailures += 1
        case .ciPassed:
            kind = .githubCIPassed; body = "CI passed."
            todayCounts.ciSuccesses += 1
        case .merged:
            kind = .githubMerged; body = "The pull request was merged."
            todayCounts.pullRequestsMerged += 1
        case .closed:
            return
        }
        onEvent?(AttentionEvent(
            kind: kind,
            key: event.dedupeKey,
            sessionID: nil,
            title: "\(pr.repository) #\(pr.number)",
            body: "\(body) \(pr.title)"
        ))
    }

    private func rollCountsIfNeeded() {
        let today = Calendar.current.startOfDay(for: .now)
        if today != countsDay {
            countsDay = today
            todayCounts = RecapGitHubInput()
        }
    }
}
