import Foundation
import Testing
@testable import ChimloCore

@Suite("Session history store")
struct SessionHistoryStoreTests {
    private let now = Date.now

    @Test("A missing file loads as empty history")
    func missingFile() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL)

        try await store.load()

        let records = await store.records()
        let outcome = await store.lastLoadOutcome
        #expect(records.isEmpty)
        #expect(outcome == .missing)
    }

    @Test("A corrupt file is moved aside, never deleted, and history starts empty")
    func corruptFileMovedAside() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: directory.historyURL)
        let store = SessionHistoryStore(fileURL: directory.historyURL)

        try await store.load()

        let outcome = await store.lastLoadOutcome
        guard case let .recoveredFromCorruption(backupURL) = outcome else {
            Issue.record("Expected corruption recovery, got \(String(describing: outcome))")
            return
        }
        #expect(backupURL.lastPathComponent.hasPrefix("history.json.corrupt-"))
        #expect(try Data(contentsOf: backupURL) == garbage)
        #expect(!FileManager.default.fileExists(atPath: directory.historyURL.path))
        let records = await store.records()
        #expect(records.isEmpty)

        await store.upsert(record(id: "after-recovery"))
        try await store.flush()
        let reloaded = SessionHistoryStore(fileURL: directory.historyURL)
        try await reloaded.load()
        let reloadedIDs = await reloaded.records().map(\.id)
        #expect(reloadedIDs == ["after-recovery"])
    }

    @Test("A newer schema is read-only: untouched on disk until explicitly cleared")
    func futureSchemaIsReadOnly() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let future = Data(#"{"schemaVersion": 99, "records": [{"shape": "unknown to this build"}]}"#.utf8)
        try future.write(to: directory.historyURL)
        let store = SessionHistoryStore(fileURL: directory.historyURL)

        try await store.load()
        let outcome = await store.lastLoadOutcome
        let readOnly = await store.isReadOnly
        let version = await store.unsupportedSchemaVersion
        #expect(outcome == .unsupportedSchema(version: 99))
        #expect(readOnly)
        #expect(version == 99)

        await store.upsert(record(id: "in-memory-only"))
        let inMemory = await store.records().map(\.id)
        #expect(inMemory == ["in-memory-only"])
        do {
            try await store.flush()
            Issue.record("Flushing a read-only store must fail")
        } catch let error as SessionHistoryStoreError {
            #expect(error == .readOnlyUnsupportedSchema(version: 99))
        }
        #expect(try Data(contentsOf: directory.historyURL) == future)

        await store.clear()
        try await store.flush()
        let cleared = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.historyURL)) as? [String: Any]
        #expect(cleared?["schemaVersion"] as? Int == SessionHistoryStore.schemaVersion)
        #expect((cleared?["records"] as? [Any])?.isEmpty == true)
    }

    @Test("A file without a schema version is treated as older and upgraded on save")
    func olderSchemaUpgrades() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let legacy = try JSONEncoder().encode(["records": [record(id: "legacy")]])
        try legacy.write(to: directory.historyURL)
        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: nil)

        try await store.load()
        try await store.flush()

        let ids = await store.records().map(\.id)
        #expect(ids == ["legacy"])
        let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.historyURL)) as? [String: Any]
        #expect(upgraded?["schemaVersion"] as? Int == SessionHistoryStore.schemaVersion)
    }

    @Test("Upserts coalesce into one background save that round-trips exactly")
    func debouncedSaveRoundTrip() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL, saveDelay: .milliseconds(50))

        var original = record(id: "session-a")
        original.events = [HistoryEvent(kind: .started, at: original.startedAt.addingTimeInterval(0.000_123))]
        original.agents = [HistoryAgent(id: "agent-1", type: "Explore")]
        await store.upsert(original)
        await store.upsert(record(id: "session-b", lastActivityOffset: -10))
        // The caller never waits for I/O: nothing is written synchronously.
        #expect(!FileManager.default.fileExists(atPath: directory.historyURL.path))

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: directory.historyURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: directory.historyURL.path))

        let reloaded = SessionHistoryStore(fileURL: directory.historyURL)
        try await reloaded.load()
        let records = await reloaded.records()
        #expect(records.map(\.id) == ["session-a", "session-b"])
        #expect(records.first == original.normalized())

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.historyURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("Flush writes immediately and upsert merges with the stored record")
    func flushAndMerge() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL, saveDelay: .seconds(60))

        await store.upsert(record(id: "session-a"))
        var finished = record(id: "session-a", status: .completed, lastActivityOffset: 30)
        finished.filesChanged = ["Sources/App.swift"]
        await store.upsert(finished)
        try await store.flush()

        let reloaded = SessionHistoryStore(fileURL: directory.historyURL)
        try await reloaded.load()
        let stored = await reloaded.record(id: "session-a")
        #expect(stored?.status == .completed)
        #expect(stored?.filesChanged == ["Sources/App.swift"])
        #expect(stored?.lastActivityAt == now.addingTimeInterval(30))
    }

    @Test("Turning previews off strips stored previews in memory and on disk")
    func previewsOffStrips() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL)
        var withPreviews = record(id: "session-a")
        withPreviews.latestUserPrompt = "synthetic-secret-prompt"
        withPreviews.latestAgentResponse = "synthetic-secret-response"
        await store.upsert(withPreviews)
        try await store.flush()

        await store.setStoresConversationPreviews(false)
        await store.upsert(withPreviews)
        try await store.flush()

        let stored = await store.record(id: "session-a")
        #expect(stored?.latestUserPrompt == nil)
        #expect(stored?.latestAgentResponse == nil)
        let text = try String(contentsOf: directory.historyURL, encoding: .utf8)
        #expect(!text.contains("synthetic-secret"))

        let reopened = SessionHistoryStore(fileURL: directory.historyURL, storesConversationPreviews: false)
        try await reopened.load()
        let reopenedRecord = await reopened.record(id: "session-a")
        #expect(reopenedRecord?.latestUserPrompt == nil)
    }

    @Test("Retention prunes old finished sessions but keeps running ones")
    func retentionKeepsRunning() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL, retentionDays: 7)
        let day: TimeInterval = 86_400
        await store.upsert(record(id: "old-completed", status: .completed, lastActivityOffset: -30 * day))
        await store.upsert(record(id: "old-running", status: .running, lastActivityOffset: -30 * day))
        await store.upsert(record(id: "old-waiting", status: .waiting, lastActivityOffset: -30 * day))
        await store.upsert(record(id: "recent-failed", status: .failed, lastActivityOffset: -1 * day))

        await store.prune(now: now)
        let kept = Set(await store.records().map(\.id))
        #expect(kept == ["old-running", "old-waiting", "recent-failed"])

        await store.setRetention(days: nil)
        await store.upsert(record(id: "ancient", status: .completed, lastActivityOffset: -900 * day))
        await store.prune(now: now)
        let unlimited = await store.record(id: "ancient")
        #expect(unlimited != nil)
    }

    @Test("Remove and clear drop records")
    func removeAndClear() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL)
        await store.upsert(record(id: "a"))
        await store.upsert(record(id: "b"))

        await store.remove(id: "a")
        let afterRemove = await store.records().map(\.id)
        #expect(afterRemove == ["b"])

        await store.clear()
        let afterClear = await store.records()
        #expect(afterClear.isEmpty)
    }

    @Test("Export writes pretty JSON with schemaVersion, exportedAt and records")
    func exportShape() async throws {
        let directory = try HistoryStoreTestDirectory()
        defer { directory.remove() }
        let store = SessionHistoryStore(fileURL: directory.historyURL)
        await store.upsert(record(id: "older", lastActivityOffset: -60))
        await store.upsert(record(id: "newer"))
        let exportURL = directory.url.appendingPathComponent("export.json")

        try await store.export(to: exportURL)

        let data = try Data(contentsOf: exportURL)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n  \"records\""))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object.map { Set($0.keys) } == ["schemaVersion", "exportedAt", "records"])
        #expect(object?["schemaVersion"] as? Int == 1)
        let exportedAt = object?["exportedAt"] as? String
        #expect(exportedAt.flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) } != nil)
        let records = object?["records"] as? [[String: Any]]
        #expect(records?.compactMap { $0["id"] as? String } == ["newer", "older"])
        #expect(records?.first?["startedAt"] is String)
    }

    private func record(
        id: String,
        status: HistoryStatus = .running,
        lastActivityOffset: TimeInterval = 0
    ) -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: id,
            projectPath: "/workspace/alpha",
            projectName: "alpha",
            title: "Synthetic session \(id)",
            startedAt: now.addingTimeInterval(lastActivityOffset - 120),
            lastActivityAt: now.addingTimeInterval(lastActivityOffset),
            status: status
        )
    }
}

/// A unique scratch directory per test so parallel tests never share files.
private struct HistoryStoreTestDirectory {
    let url: URL
    var historyURL: URL { url.appendingPathComponent("history.json") }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
