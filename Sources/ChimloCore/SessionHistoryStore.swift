import Foundation

/// What the most recent `load()` found on disk, so the UI can explain an empty
/// or read-only history instead of silently showing nothing.
public enum SessionHistoryLoadOutcome: Equatable, Sendable {
    case missing
    case loaded(recordCount: Int)
    /// The file could not be decoded. It was moved to `backupURL`, never deleted.
    case recoveredFromCorruption(backupURL: URL)
    /// Written by a newer build. The file is untouched and the store is read-only.
    case unsupportedSchema(version: Int)
}

public enum SessionHistoryStoreError: Error, Equatable, Sendable {
    /// The history file has a schema newer than this build understands.
    /// Writing would destroy data the newer build can still read, so every
    /// write is refused until `clear()` is called explicitly.
    case readOnlyUnsupportedSchema(version: Int)
    /// A corrupt file could not be moved aside; overwriting it would lose it.
    case cannotPreserveCorruptFile(path: String)
    /// The file is there but could not be read (permissions, a disk error).
    /// It is left exactly where it is and nothing is written over it.
    case cannotReadFile(path: String, reason: String)
    case writeFailed(path: String, reason: String)
}

/// Durable, local-only session history.
///
/// Design notes:
/// - Updates are frequent (every hook event), so `upsert` only mutates memory
///   and coalesces writes: the first change schedules one save `saveDelay`
///   later and later changes ride along. A strict trailing debounce would
///   never save during a busy session.
/// - Writes are atomic (temp file + rename) and owner-only (0600) because the
///   file can contain prompt previews.
/// - The file is never deleted on failure: a corrupt file is moved aside and a
///   file from a newer schema makes the store read-only until `clear()`.
/// - Dates are stored in Foundation's native representation so they round-trip
///   exactly; event dedupe relies on exact timestamps.
public actor SessionHistoryStore {
    public static let schemaVersion = 1
    /// Bounds the file size; previews are for recognition, not archival.
    public static let maxPreviewLength = 2_000
    /// A record still marked running or waiting after this long without
    /// activity belongs to a session that ended unseen (the terminal was
    /// closed, the Mac restarted). The notch only follows a session for
    /// `SessionVisibilityPolicy.activityLifetime` (two hours) after its last
    /// activity, so six times that can never be a session it still reports.
    public static let staleActiveInterval: TimeInterval = 12 * 60 * 60

    public nonisolated let fileURL: URL
    public private(set) var storesConversationPreviews: Bool
    public private(set) var retentionDays: Int?
    public private(set) var lastLoadOutcome: SessionHistoryLoadOutcome?
    /// Description of the last background save failure, cleared on success.
    public private(set) var lastSaveError: String?

    /// Non-nil while the on-disk file is from an unsupported (newer) schema.
    public var unsupportedSchemaVersion: Int? {
        if case let .unsupportedSchema(version) = writeBlock { return version }
        return nil
    }

    /// True while writing would destroy a file this build cannot preserve.
    public var isReadOnly: Bool { writeBlock != nil }

    private enum WriteBlock: Equatable {
        case unsupportedSchema(Int)
        case unpreservedCorruptFile
    }

    private let saveDelay: Duration
    private var recordsByID: [String: SessionHistoryRecord] = [:]
    private var isDirty = false
    private var writeBlock: WriteBlock?
    private var pendingSave: Task<Void, Never>?
    /// How many times the history has been written to disk. Tests count
    /// writes with it; the app has no use for it.
    private(set) var completedSaves = 0
    /// Identifies the current scheduled save so a superseded timer that wakes
    /// late (after `flush()`) cannot clear its successor.
    private var saveGeneration = 0

    public init(
        fileURL: URL,
        storesConversationPreviews: Bool = true,
        retentionDays: Int? = 90,
        saveDelay: Duration = .milliseconds(500)
    ) {
        self.fileURL = fileURL
        self.storesConversationPreviews = storesConversationPreviews
        self.retentionDays = retentionDays.map { max(1, $0) }
        self.saveDelay = saveDelay
    }

    // MARK: Loading

    /// Reads the history file and merges it into memory.
    ///
    /// - Missing file: empty history.
    /// - Undecodable file: moved to `<name>.corrupt-<unix>` and history starts
    ///   empty. Throws only if the file cannot be moved, because the next save
    ///   would otherwise overwrite it; the store is then left read-only.
    /// - Older schema: decoded with the tolerant record decoder and rewritten
    ///   as the current schema on the next save.
    /// - Newer schema: nothing is loaded, the file is left untouched, and all
    ///   writes are refused until `clear()` (an explicit, user-initiated reset).
    ///
    /// Records already upserted before `load()` are merged on top of the disk
    /// copy, so an early hook event is never lost to a late load.
    public func load() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastLoadOutcome = .missing
            return
        }

        // A file that cannot be read is not a corrupt file: it may be fine
        // and only out of reach for now. It stays where it is, and writes
        // are refused so nothing replaces it.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            writeBlock = .unpreservedCorruptFile
            throw SessionHistoryStoreError.cannotReadFile(path: fileURL.path, reason: error.localizedDescription)
        }

        let envelope: StoredEnvelope
        do {
            let header = try JSONDecoder().decode(SchemaHeader.self, from: data)
            let version = header.schemaVersion ?? 0
            if version > Self.schemaVersion {
                writeBlock = .unsupportedSchema(version)
                lastLoadOutcome = .unsupportedSchema(version: version)
                return
            }
            envelope = try JSONDecoder().decode(StoredEnvelope.self, from: data)
        } catch {
            let backupURL: URL
            do {
                backupURL = try moveAsideCorruptFile()
            } catch {
                // Keep the file and refuse writes, like an unsupported schema.
                writeBlock = .unpreservedCorruptFile
                throw SessionHistoryStoreError.cannotPreserveCorruptFile(path: fileURL.path)
            }
            lastLoadOutcome = .recoveredFromCorruption(backupURL: backupURL)
            return
        }

        // Records that could not be read were left out above. Before the
        // file is ever rewritten without them, the whole original is kept
        // beside it; if that copy cannot be made, nothing is written.
        if envelope.unreadableRecordCount > 0 {
            do {
                _ = try copyAsideCorruptFile()
            } catch {
                writeBlock = .unpreservedCorruptFile
                throw SessionHistoryStoreError.cannotPreserveCorruptFile(path: fileURL.path)
            }
        }

        writeBlock = nil
        var changed = (envelope.schemaVersion ?? 0) < Self.schemaVersion || envelope.unreadableRecordCount > 0
        for stored in envelope.records {
            let disk = applyPreviewPolicy(stored)
            if disk != stored { changed = true }
            if let inMemory = recordsByID[stored.id] {
                recordsByID[stored.id] = disk.merged(with: inMemory)
                changed = true
            } else {
                recordsByID[stored.id] = disk.normalized()
            }
        }
        if pruneExpired(now: .now) { changed = true }
        lastLoadOutcome = .loaded(recordCount: envelope.records.count)
        // `isDirty` covers changes held back while a previous load blocked writes.
        if changed || isDirty { scheduleSave() }
    }

    // MARK: Reading

    /// Newest activity first; ties break by id so the order is stable.
    public func records() -> [SessionHistoryRecord] {
        recordsByID.values.sorted(by: SessionHistoryOrdering.newestFirst)
    }

    public func record(id: String) -> SessionHistoryRecord? {
        recordsByID[id]
    }

    // MARK: Writing

    /// Merges a snapshot into the existing record (or inserts it) and schedules
    /// a coalesced save. Never performs I/O on the caller's path.
    public func upsert(_ record: SessionHistoryRecord) {
        let incoming = applyPreviewPolicy(record)
        if let existing = recordsByID[incoming.id] {
            let merged = existing.merged(with: incoming)
            guard merged != existing else { return }
            recordsByID[incoming.id] = merged
        } else {
            recordsByID[incoming.id] = incoming.normalized()
        }
        scheduleSave()
    }

    public func remove(id: String) {
        guard recordsByID.removeValue(forKey: id) != nil else { return }
        scheduleSave()
    }

    /// Discards all history. This is also the explicit reset that lifts the
    /// read-only state of a newer-schema file: the next save replaces it.
    public func clear() {
        recordsByID.removeAll()
        writeBlock = nil
        scheduleSave()
    }

    /// `nil` keeps history forever; other values are clamped to at least one
    /// day. Expired records are pruned immediately so the setting takes effect.
    public func setRetention(days: Int?) {
        retentionDays = days.map { max(1, $0) }
        prune()
    }

    /// Turning previews off also strips previews already stored, in memory and
    /// (on the next save) on disk.
    public func setStoresConversationPreviews(_ value: Bool) {
        storesConversationPreviews = value
        guard !value else { return }
        var changed = false
        for (id, record) in recordsByID {
            let stripped = applyPreviewPolicy(record)
            if stripped != record {
                recordsByID[id] = stripped
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    /// Drops records whose last activity is older than the retention window.
    /// Running and waiting sessions are kept while they can still be live;
    /// one idle for `staleActiveInterval` is marked interrupted first, and
    /// from then on ages out like any finished session.
    public func prune(now: Date = .now) {
        if pruneExpired(now: now) { scheduleSave() }
    }

    /// Writes pending changes immediately (no-op when nothing changed). Call
    /// before quitting; also used by tests instead of waiting for the timer.
    public func flush() async throws {
        pendingSave?.cancel()
        pendingSave = nil
        saveGeneration += 1
        try writeIfDirty()
    }

    /// Waits for the save now scheduled, if there is one. For tests, so they
    /// wait for the save itself and not for a guessed length of time; the
    /// app never waits on a save.
    func scheduledSaveFinished() async {
        await pendingSave?.value
    }

    /// Writes a human-readable copy: `{schemaVersion, exportedAt, records}`
    /// with ISO 8601 dates and sorted keys. The preview policy already applies
    /// to the in-memory records, so an export never leaks stripped previews.
    public func export(to url: URL) throws {
        let envelope = ExportEnvelope(
            schemaVersion: Self.schemaVersion,
            exportedAt: .now,
            records: records()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Internals

    private func applyPreviewPolicy(_ record: SessionHistoryRecord) -> SessionHistoryRecord {
        var record = record
        if storesConversationPreviews {
            record.latestUserPrompt = record.latestUserPrompt.map(Self.cappedPreview)
            record.latestAgentResponse = record.latestAgentResponse.map(Self.cappedPreview)
        } else {
            record.latestUserPrompt = nil
            record.latestAgentResponse = nil
        }
        return record
    }

    private static func cappedPreview(_ text: String) -> String {
        text.count > maxPreviewLength ? String(text.prefix(maxPreviewLength)) : text
    }

    /// Returns whether anything was changed or removed.
    private func pruneExpired(now: Date) -> Bool {
        let interrupted = interruptStaleActive(now: now)
        guard let retentionDays else { return interrupted }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let expired = recordsByID.values.filter { !$0.status.isActive && $0.lastActivityAt < cutoff }
        for record in expired { recordsByID.removeValue(forKey: record.id) }
        return interrupted || !expired.isEmpty
    }

    /// Marks running and waiting records that went quiet long ago as
    /// interrupted. Nothing ever reports the end of a session that was
    /// killed mid-turn, so without this its record says "Running" for good
    /// and retention, which keeps active sessions, never removes it. Only the
    /// status and the end time change; a session that does come back is
    /// running again on its next update, because a newer status wins a merge.
    private func interruptStaleActive(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.staleActiveInterval)
        var changed = false
        for (id, record) in recordsByID where record.status.isActive && record.lastActivityAt < cutoff {
            var interrupted = record
            interrupted.status = .interrupted
            // Last seen then. An earlier end (a turn that finished before the
            // session went on) would understate how long it ran.
            interrupted.endedAt = max(record.endedAt ?? record.lastActivityAt, record.lastActivityAt)
            recordsByID[id] = interrupted
            changed = true
        }
        return changed
    }

    private func scheduleSave() {
        isDirty = true
        // A read-only store keeps changes in memory; `flush()` reports why
        // they cannot be written instead of a timer failing repeatedly.
        guard pendingSave == nil, writeBlock == nil else { return }
        saveGeneration += 1
        let generation = saveGeneration
        let delay = saveDelay
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.performScheduledSave(generation: generation)
        }
    }

    private func performScheduledSave(generation: Int) {
        guard generation == saveGeneration else { return }
        pendingSave = nil
        do {
            try writeIfDirty()
            lastSaveError = nil
        } catch {
            lastSaveError = String(describing: error)
        }
    }

    private func writeIfDirty() throws {
        guard isDirty else { return }
        switch writeBlock {
        case let .unsupportedSchema(version):
            throw SessionHistoryStoreError.readOnlyUnsupportedSchema(version: version)
        case .unpreservedCorruptFile:
            throw SessionHistoryStoreError.cannotPreserveCorruptFile(path: fileURL.path)
        case nil:
            break
        }
        let envelope = StoredEnvelope(
            schemaVersion: Self.schemaVersion,
            savedAt: .now,
            records: records()
        )
        let data = try JSONEncoder().encode(envelope)
        try writeAtomically(data)
        isDirty = false
        completedSaves += 1
    }

    private func writeAtomically(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw SessionHistoryStoreError.writeFailed(path: fileURL.path, reason: String(describing: error))
        }
        // rename(2) replaces the destination atomically on the same volume, so
        // a crash leaves either the old file or the new one, never half of one.
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fileManager.removeItem(at: temporaryURL)
            throw SessionHistoryStoreError.writeFailed(path: fileURL.path, reason: reason)
        }
    }

    private func moveAsideCorruptFile() throws -> URL {
        let candidate = corruptBackupURL()
        try FileManager.default.moveItem(at: fileURL, to: candidate)
        return candidate
    }

    /// Keeps the whole original beside the file, for when only some of its
    /// records could be read and the rest are about to be saved without them.
    private func copyAsideCorruptFile() throws -> URL {
        let candidate = corruptBackupURL()
        try FileManager.default.copyItem(at: fileURL, to: candidate)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        return candidate
    }

    private func corruptBackupURL() -> URL {
        let fileManager = FileManager.default
        let base = "\(fileURL.lastPathComponent).corrupt-\(Int(Date.now.timeIntervalSince1970))"
        let directory = fileURL.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(base)
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}

/// Shared ordering for every history list.
enum SessionHistoryOrdering {
    static func newestFirst(_ lhs: SessionHistoryRecord, _ rhs: SessionHistoryRecord) -> Bool {
        lhs.lastActivityAt != rhs.lastActivityAt ? lhs.lastActivityAt > rhs.lastActivityAt : lhs.id < rhs.id
    }
}

/// Decoded first so a newer schema is detected before its records are parsed.
private struct SchemaHeader: Decodable {
    let schemaVersion: Int?
}

private struct StoredEnvelope: Codable {
    let schemaVersion: Int?
    var savedAt: Date?
    let records: [SessionHistoryRecord]
    /// Records in the file that could not be read. One of them no longer
    /// takes every other session's history with it.
    var unreadableRecordCount = 0

    init(schemaVersion: Int?, savedAt: Date?, records: [SessionHistoryRecord]) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.records = records
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, savedAt, records }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        savedAt = try? container.decodeIfPresent(Date.self, forKey: .savedAt)
        let stored = try container.decode([ReadableRecord].self, forKey: .records)
        records = stored.compactMap(\.record)
        unreadableRecordCount = stored.count - records.count
    }

    private struct ReadableRecord: Decodable {
        let record: SessionHistoryRecord?
        init(from decoder: any Decoder) throws { record = try? SessionHistoryRecord(from: decoder) }
    }
}

private struct ExportEnvelope: Encodable {
    let schemaVersion: Int
    let exportedAt: Date
    let records: [SessionHistoryRecord]
}
