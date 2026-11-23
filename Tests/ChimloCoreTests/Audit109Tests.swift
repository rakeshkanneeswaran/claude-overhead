import Foundation
import Testing
@testable import ChimloCore

/// Regression tests for the 1.0.9 audit: things found by reading the whole
/// app again after the character feature, each with the failure it caused.
@Suite("Audit 1.0.9")
struct Audit109Tests {
    // MARK: A model name can no longer crash the app

    @Test("A model id with nothing after \"claude\" has no display name, and does not trap",
          arguments: ["claude", "my-claude", "bedrock/claude", "claude@", "claude@20250101", "claude-v-2", "v", "v:", "claude-v:", "@", ""])
    func oddModelIDs(id: String) {
        // Through 1.0.8 some of these indexed an empty list. The app rebuilt
        // its session list on every event, so one such session crashed it,
        // and again at each launch for a day.
        _ = ModelDisplayName.resolve(modelID: id, agent: .claude)
    }

    // MARK: A failed turn is read from the session file

    private static func candidate(after lines: [String]) throws -> SessionCandidate {
        var scanner = PrivacySafeSessionMetadataScanner()
        for line in lines { scanner.consume(line: Data(line.utf8)) }
        return try #require(scanner.candidate(transcriptPath: "/tmp/claude-1.jsonl", fallbackUpdatedAt: .distantPast))
    }

    private static let prompt = #"{"sessionId":"claude-1","cwd":"/tmp/p","type":"user","message":{"role":"user","content":"Run the tests"}}"#
    private static let reply = #"{"sessionId":"claude-1","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","stop_reason":"end_turn","content":[{"type":"text","text":"All green."}]}}"#
    /// What Claude Code writes when a turn ends in an API error: an assistant
    /// line whose stop reason reads like a normal end, marked as an error,
    /// from a placeholder model.
    private static let apiError = #"{"sessionId":"claude-1","type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error: Connection error."}]}}"#

    @Test("A turn that ended in an API error is failed, not finished")
    func apiErrorIsAFailure() throws {
        #expect(try Self.candidate(after: [Self.prompt, Self.apiError]).phase == .failed)
        // The same stop reason without the error mark is an ordinary end.
        let ordinary = Self.apiError.replacingOccurrences(of: #""isApiErrorMessage":true,"#, with: "")
        #expect(try Self.candidate(after: [Self.prompt, ordinary]).phase == .completed)
        // The next prompt starts a normal turn again, and a reply ends it.
        #expect(try Self.candidate(after: [Self.prompt, Self.apiError, Self.prompt]).phase == .working)
        #expect(try Self.candidate(after: [Self.prompt, Self.apiError, Self.prompt, Self.reply]).phase == .completed)
    }

    @Test("The error line's placeholder model does not replace the session's model")
    func errorLineKeepsTheModel() throws {
        let failed = try Self.candidate(after: [Self.prompt, Self.reply, Self.prompt, Self.apiError])
        #expect(failed.model == "claude-sonnet-5")
        #expect(try Self.candidate(after: [Self.prompt, Self.apiError]).model != "<synthetic>")
    }

    // MARK: Large hook events are not dropped

    @Test("A prompt far larger than 64 KB still tells the app the session is working")
    func largeObserverPayload() throws {
        let paste = String(repeating: "lorem ipsum ", count: 40_000)
        let payload = Data(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","cwd":"/work/app","prompt":"\#(paste)"}"#.utf8)
        #expect(payload.count > 400_000)
        let event = try #require(try PrivacySafeHookMapper.event(from: payload, source: .claude))
        #expect(event.kind == .activity)
        #expect(PrivacySafeHookMapper.maximumPayloadBytes == ClaudePermissionHook.maximumPayloadBytes)
        // The size limit still holds above it.
        let tooLarge = Data(count: PrivacySafeHookMapper.maximumPayloadBytes + 1)
        #expect(throws: ProviderHookMappingError.self) {
            try PrivacySafeHookMapper.event(from: tooLarge, source: .claude)
        }
    }

    // MARK: Numbers read from files are kept in range

    @Test("A usage percentage from a file is clamped like one made in code")
    func capacityPercentageIsClamped() throws {
        func window(_ used: String) throws -> CapacityWindowSnapshot {
            try JSONDecoder().decode(CapacityWindowSnapshot.self, from: Data(
                #"{"provider":"claude","kind":"session","usedPercentage":\#(used),"observedAt":800000000,"source":"claudeStatusLine"}"#.utf8
            ))
        }
        #expect(try window("42.5").usedPercentage == 42.5)
        // Valid JSON, and far outside anything that can be shown. Turning it
        // into a whole number used to trap in the usage row.
        #expect(try window("1e300").usedPercentage == 100)
        #expect(try window("-5").usedPercentage == 0)
        #expect(Int(try window("1e300").usedPercentage.rounded()) == 100)
        // A window saved by this version reads back the same.
        let saved = try window("73")
        #expect(try JSONDecoder().decode(CapacityWindowSnapshot.self, from: JSONEncoder().encode(saved)) == saved)
    }

    // MARK: History survives one bad record and a file it cannot read

    private static func historyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-audit109-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func record(_ id: String) -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: id,
            projectPath: "/workspace/alpha",
            projectName: "alpha",
            title: "Synthetic session \(id)",
            startedAt: Date.now.addingTimeInterval(-120),
            lastActivityAt: .now,
            status: .completed
        )
    }

    @Test("One unreadable history record no longer hides every other session, and the original is kept")
    func oneBadHistoryRecord() async throws {
        let directory = try Self.historyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")

        let first = SessionHistoryStore(fileURL: fileURL)
        for id in ["a", "b", "c"] { await first.upsert(Self.record(id)) }
        try await first.flush()

        // Damage one record in the file as a bad write or a hand edit might.
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var records = try #require(object["records"] as? [Any])
        #expect(records.count == 3)
        records[1] = ["id": 7, "title": ["not", "a", "title"]]
        object["records"] = records
        let damaged = try JSONSerialization.data(withJSONObject: object)
        try damaged.write(to: fileURL)

        let store = SessionHistoryStore(fileURL: fileURL)
        try await store.load()
        let loaded = await store.records()
        #expect(loaded.count == 2)
        // The whole original, bad record included, is beside the file.
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("history.json.corrupt-") }
        #expect(backups.count == 1)
        let backup = try Data(contentsOf: directory.appendingPathComponent(try #require(backups.first)))
        #expect(backup == damaged)
        // And the history file itself is still in place.
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("A history file that cannot be read is left exactly where it is")
    func unreadableHistoryFile() async throws {
        let directory = try Self.historyDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: directory.appendingPathComponent("history.json").path)
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("history.json")
        let first = SessionHistoryStore(fileURL: fileURL)
        await first.upsert(Self.record("a"))
        try await first.flush()
        let original = try Data(contentsOf: fileURL)

        // Readable by nobody: a permissions problem, not a damaged file.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        let store = SessionHistoryStore(fileURL: fileURL)
        await #expect(throws: SessionHistoryStoreError.self) { try await store.load() }

        // Nothing was moved aside and nothing was written over it.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["history.json"])
        await store.upsert(Self.record("b"))
        await #expect(throws: SessionHistoryStoreError.self) { try await store.flush() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        #expect(try Data(contentsOf: fileURL) == original)
    }

    // MARK: Claude Code's settings file stays readable

    @Test("Paths in the owner's settings file are written plainly, not with escaped slashes")
    func settingsKeepPlainSlashes() throws {
        let existing = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/me/bin/notify"}]}]}}"#.utf8)
        let merged = try ClaudeHookConfiguration.merging(
            existingData: existing,
            helperPath: "/Users/me/Library/Application Support/Overhead/bin/overhead"
        )
        let text = String(decoding: merged.data, as: UTF8.self)
        #expect(text.contains("/Users/me/bin/notify"))
        #expect(!text.contains(#"\/"#))
    }
}
