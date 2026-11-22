import ChimloCore
import Foundation

/// Local session history: a summary of every Claude Code session this Mac
/// has seen, kept in one file under Application Support. It holds no full
/// transcripts (Claude Code keeps those), never leaves the Mac, and is pruned
/// by the owner's retention setting.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var records: [SessionHistoryRecord] = []
    @Published private(set) var loadOutcome: SessionHistoryLoadOutcome?
    @Published private(set) var problem: String?

    let store: SessionHistoryStore
    private let gitReader = GitRepositoryReader()
    private var firstSeen: [String: Date] = [:]
    private var lastUpserted: [String: SessionHistoryRecord] = [:]
    private var refreshTask: Task<Void, Never>?

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Overhead/history", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    init(fileURL: URL = HistoryModel.defaultFileURL, settings: OverheadSettings) {
        store = SessionHistoryStore(
            fileURL: fileURL,
            storesConversationPreviews: settings.storeConversationPreviews,
            retentionDays: settings.historyRetentionDays
        )
    }

    func start() {
        Task {
            do {
                try await store.load()
            } catch {
                problem = Self.describe(error)
            }
            loadOutcome = await store.lastLoadOutcome
            if case let .unsupportedSchema(version) = loadOutcome {
                problem = "History was written by a newer Overhead (format \(version)). It is shown read-only and left untouched."
            }
            await reload()
        }
    }

    func stop() {
        refreshTask?.cancel()
        let store = store
        Task { try? await store.flush() }
    }

    /// Records what the notch knows about each live or recent session.
    func observe(_ sessions: [SessionDisplayModel], now: Date = .now) {
        var changed = false
        for session in sessions where !session.isDemo {
            let record = Self.record(from: session, firstSeen: firstSeenDate(for: session, now: now))
            guard lastUpserted[session.id] != record else { continue }
            lastUpserted[session.id] = record
            changed = true
            let store = store
            Task { await store.upsert(record) }
        }
        if changed { scheduleReload() }
    }

    func applySettings(_ settings: OverheadSettings, previous: OverheadSettings?) {
        let store = store
        if previous?.historyRetentionDays != settings.historyRetentionDays {
            let days = settings.historyRetentionDays
            Task { await store.setRetention(days: days); await reload() }
        }
        if previous?.storeConversationPreviews != settings.storeConversationPreviews {
            let keep = settings.storeConversationPreviews
            Task { await store.setStoresConversationPreviews(keep); await reload() }
        }
    }

    func remove(id: String) {
        let store = store
        lastUpserted.removeValue(forKey: id)
        Task { await store.remove(id: id); await reload() }
    }

    /// Deletes all of Overhead's history. Claude Code's own transcripts are
    /// not touched.
    func clearAll() {
        let store = store
        lastUpserted.removeAll()
        Task {
            await store.clear()
            try? await store.flush()
            await reload()
        }
    }

    func export(to url: URL) async throws {
        try await store.flush()
        try await store.export(to: url)
    }

    func search(_ query: HistoryQuery) -> [SessionHistoryRecord] {
        HistorySearch.filter(records, query: query)
    }

    func record(id: String) -> SessionHistoryRecord? {
        records.first { $0.id == id }
    }

    /// A receipt built from the history record and, when the project is a git
    /// repository, git's own view of what changed during the session.
    func receipt(for record: SessionHistoryRecord) async -> SessionReceipt {
        guard let path = record.projectPath,
              let info = await gitReader.info(for: path),
              let summary = await gitReader.changes(in: info.root, since: record.startedAt) else {
            return SessionReceiptBuilder.build(record: record, git: nil)
        }
        let git = ReceiptGitInput(
            branch: info.branch,
            files: summary.files.map { ReceiptFileChange(path: $0.path, added: $0.added, removed: $0.removed) },
            commits: summary.commits.map { ReceiptCommit(sha: $0.sha, subject: $0.subject) },
            insertions: summary.insertions,
            deletions: summary.deletions
        )
        return SessionReceiptBuilder.build(record: record, git: git)
    }

    func recap(for day: Date, github: RecapGitHubInput?) -> DailyRecap {
        DailyRecapBuilder.build(records: records, day: day, github: github)
    }

    func pulses(liveSessionIDs: Set<String>, attentionSessionIDs: Set<String>) -> [ProjectPulse] {
        ProjectPulseBuilder.build(
            records: records,
            liveSessionIDs: liveSessionIDs,
            attentionSessionIDs: attentionSessionIDs
        )
    }

    func timeline(projectKey: String) -> [ProjectTimelineEntry] {
        ProjectTimelineBuilder.entries(records: records, projectKey: projectKey)
    }

    /// Project folders seen recently, for repository discovery.
    func recentProjectPaths(within days: Int = 14, now: Date = .now) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var seen = Set<String>()
        return records
            .filter { $0.lastActivityAt >= cutoff }
            .compactMap(\.projectPath)
            .filter { seen.insert($0).inserted }
    }

    // MARK: Private

    private func firstSeenDate(for session: SessionDisplayModel, now: Date) -> Date {
        if let started = session.live?.startedAt { return started }
        if let known = firstSeen[session.id] { return known }
        let date = min(now, session.updatedAt)
        firstSeen[session.id] = date
        return date
    }

    private func scheduleReload() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            refreshTask = nil
            await reload()
        }
    }

    private func reload() async {
        let latest = await store.records()
        if latest != records { records = latest }
        if let error = await store.lastSaveError {
            problem = "History could not be saved: \(error)"
        }
    }

    static func record(from session: SessionDisplayModel, firstSeen: Date) -> SessionHistoryRecord {
        let insights = session.insights
        let projectName = session.projectPath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? session.title
        let state: SessionActivityState = switch session.mood {
        case .working: .working
        case .waiting: .waitingForPermission
        case .question: .waitingForAnswer
        case .success: .finished
        case .failed: .failed
        case .idle: .idle
        }
        let status = state.historyStatus
        let ended = status == .completed || status == .failed ? session.updatedAt : nil
        var events: [HistoryEvent] = [HistoryEvent(kind: .started, at: firstSeen)]
        for compaction in insights?.compactions ?? [] {
            if let at = compaction.at {
                events.append(HistoryEvent(kind: .compacted, at: at, detail: compaction.trigger))
            }
        }
        if let ended {
            events.append(HistoryEvent(kind: status == .failed ? .failed : .completed, at: ended))
        }
        return SessionHistoryRecord(
            id: session.id,
            projectPath: session.projectPath,
            projectName: projectName,
            title: session.title,
            startedAt: min(firstSeen, session.updatedAt),
            lastActivityAt: session.updatedAt,
            status: status,
            endedAt: ended,
            model: session.model ?? insights?.model,
            gitBranch: insights?.gitBranch,
            latestUserPrompt: session.latestUserPrompt,
            latestAgentResponse: session.latestAgentResponse,
            costUSD: insights?.cost?.totalUSD,
            linesAdded: insights?.cost?.linesAdded,
            linesRemoved: insights?.cost?.linesRemoved,
            filesChanged: insights?.filesTouched ?? [],
            agents: (insights?.agents ?? []).map {
                HistoryAgent(
                    id: $0.id,
                    type: $0.subagentType,
                    description: $0.description,
                    startedAt: $0.startedAt,
                    finishedAt: $0.finishedAt,
                    failed: $0.failed
                )
            },
            tests: (insights?.testRuns ?? []).map {
                HistoryTestRun(command: $0.command, outcome: $0.outcome.rawValue)
            },
            pullRequests: (insights?.pullRequests ?? []).map {
                HistoryPullRequest(number: $0.number, url: $0.url, repository: $0.repository)
            },
            events: events,
            contextPeakFraction: insights?.contextFraction
        )
    }

    private static func describe(_ error: Error) -> String {
        switch error as? SessionHistoryStoreError {
        case let .cannotPreserveCorruptFile(path):
            "History at \(path) is damaged and could not be set aside, so Overhead will not write to it."
        case let .writeFailed(_, reason):
            "History could not be saved: \(reason)"
        case let .readOnlyUnsupportedSchema(version):
            "History was written by a newer Overhead (format \(version)) and is read-only."
        case nil:
            error.localizedDescription
        }
    }
}
