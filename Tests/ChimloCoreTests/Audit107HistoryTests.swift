import Foundation
import Testing
@testable import ChimloCore

@Suite("Audit 1.0.7: history records left on running")
struct Audit107HistoryStaleRunningTests {
    private let now = Date.now
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    @Test("On load, a session that went quiet long ago is interrupted; one that may be live is untouched")
    func loadInterruptsStaleSessions() async throws {
        let directory = try AuditHistoryDirectory()
        defer { directory.remove() }
        let writer = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: nil)
        await writer.upsert(record(id: "killed-mid-turn", status: .running, idleFor: 13 * hour))
        await writer.upsert(record(id: "closed-at-a-prompt", status: .waiting, idleFor: 3 * day))
        await writer.upsert(record(id: "working-now", status: .running, idleFor: 60))
        await writer.upsert(record(id: "waiting-since-lunch", status: .waiting, idleFor: 5 * hour))
        await writer.upsert(record(id: "finished", status: .completed, idleFor: 3 * day))
        try await writer.flush()

        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: nil)
        try await store.load()

        let killed = try #require(await store.record(id: "killed-mid-turn"))
        #expect(killed.status == .interrupted)
        #expect(killed.endedAt == killed.lastActivityAt, "it ended when it was last seen")
        #expect(await store.record(id: "closed-at-a-prompt")?.status == .interrupted)
        #expect(await store.record(id: "working-now")?.status == .running)
        #expect(await store.record(id: "waiting-since-lunch")?.status == .waiting)
        #expect(await store.record(id: "finished")?.status == .completed)
        #expect(await store.records().count == 5, "nothing is deleted without a retention limit")

        // The change is saved through the usual atomic write: a current-schema
        // file, owner-only, and no temporary file left beside it.
        try await store.flush()
        let reopened = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: nil)
        try await reopened.load()
        #expect(await reopened.lastLoadOutcome == .loaded(recordCount: 5))
        #expect(await reopened.record(id: "killed-mid-turn")?.status == .interrupted)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.historyURL)) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == SessionHistoryStore.schemaVersion)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.historyURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["history.json"])
    }

    @Test("The threshold is conservative: well past the two hours the notch follows a session")
    func thresholdIsConservative() async throws {
        #expect(SessionHistoryStore.staleActiveInterval >= 6 * hour)
        #expect(SessionHistoryStore.staleActiveInterval >= 3 * SessionVisibilityPolicy.activityLifetime)

        let directory = try AuditHistoryDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: nil)
        let justInside = SessionHistoryStore.staleActiveInterval - 60
        await store.upsert(record(id: "inside", status: .running, idleFor: justInside))
        await store.upsert(record(id: "outside", status: .running, idleFor: SessionHistoryStore.staleActiveInterval + 60))

        await store.prune(now: now)

        #expect(await store.record(id: "inside")?.status == .running)
        #expect(await store.record(id: "outside")?.status == .interrupted)
    }

    @Test("Once interrupted, a stale session ages out by the owner's retention and no sooner")
    func retentionAppliesAfterInterruption() async throws {
        let directory = try AuditHistoryDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: 7)
        await store.upsert(record(id: "stale-30-days", status: .running, idleFor: 30 * day))
        await store.upsert(record(id: "stale-2-days", status: .waiting, idleFor: 2 * day))
        await store.upsert(record(id: "live", status: .running, idleFor: 10 * 60))
        await store.upsert(record(id: "done-2-days", status: .completed, idleFor: 2 * day))

        await store.prune(now: now)

        #expect(await store.record(id: "stale-30-days") == nil, "past retention, like any finished session")
        #expect(await store.record(id: "stale-2-days")?.status == .interrupted, "inside retention: kept")
        #expect(await store.record(id: "live")?.status == .running)
        #expect(await store.record(id: "done-2-days")?.status == .completed)

        // Keeping history forever keeps these too; only the label changes.
        await store.setRetention(days: nil)
        await store.upsert(record(id: "ancient", status: .running, idleFor: 900 * day))
        await store.prune(now: now)
        #expect(await store.record(id: "ancient")?.status == .interrupted)
    }

    @Test("A session that comes back is running again, and an idle report does not undo the interruption")
    func resumedSessionRunsAgain() async throws {
        let directory = try AuditHistoryDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: nil)
        await store.upsert(record(id: "resumed", status: .running, idleFor: 2 * day))
        await store.prune(now: now)
        #expect(await store.record(id: "resumed")?.status == .interrupted)

        // Idle maps to `.unknown`, which never overrides a known status.
        await store.upsert(record(id: "resumed", status: .unknown, idleFor: 2 * day))
        #expect(await store.record(id: "resumed")?.status == .interrupted)

        await store.upsert(record(id: "resumed", status: .running, idleFor: 0))
        let resumed = try #require(await store.record(id: "resumed"))
        #expect(resumed.status == .running)
        #expect(resumed.lastActivityAt == now)

        await store.prune(now: now)
        #expect(await store.record(id: "resumed")?.status == .running, "live again, so left alone")
    }

    @Test("An earlier turn's end does not understate an interrupted session")
    func endMovesToLastActivity() async throws {
        let directory = try AuditHistoryDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: nil)
        var stale = record(id: "went-on", status: .running, idleFor: 2 * day)
        // A turn finished an hour before the last activity, then work went on.
        stale.endedAt = stale.lastActivityAt.addingTimeInterval(-hour)
        await store.upsert(stale)

        await store.prune(now: now)

        let interrupted = try #require(await store.record(id: "went-on"))
        #expect(interrupted.status == .interrupted)
        #expect(interrupted.endedAt == interrupted.lastActivityAt)
        #expect(interrupted.startedAt == stale.startedAt)
        #expect(interrupted.latestUserPrompt == stale.latestUserPrompt, "nothing but status and end changes")
    }

    @Test("A history file from a newer build is still left exactly as it is")
    func newerSchemaUntouched() async throws {
        let directory = try AuditHistoryDirectory()
        defer { directory.remove() }
        let staleStart = now.addingTimeInterval(-40 * day).timeIntervalSinceReferenceDate
        let future = Data(#"{"schemaVersion": 99, "records": [{"id": "old", "status": "running", "startedAt": \#(staleStart), "lastActivityAt": \#(staleStart)}]}"#.utf8)
        try future.write(to: directory.historyURL)
        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: 7)

        try await store.load()
        await store.prune(now: now)
        try? await store.flush()

        #expect(await store.lastLoadOutcome == .unsupportedSchema(version: 99))
        #expect(try Data(contentsOf: directory.historyURL) == future)
    }

    private func record(id: String, status: HistoryStatus, idleFor: TimeInterval) -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: id,
            projectPath: "/workspace/alpha",
            projectName: "alpha",
            title: "Synthetic session \(id)",
            startedAt: now.addingTimeInterval(-idleFor - 120),
            lastActivityAt: now.addingTimeInterval(-idleFor),
            status: status,
            latestUserPrompt: "Synthetic prompt for \(id)"
        )
    }
}

/// A unique scratch directory per test so parallel tests never share files.
private struct AuditHistoryDirectory {
    let url: URL
    var historyURL: URL { url.appendingPathComponent("history.json") }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-audit-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
