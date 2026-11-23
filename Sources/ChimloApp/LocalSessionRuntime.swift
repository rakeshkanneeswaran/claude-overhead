import AppKit
import ChimloCore
import Foundation

struct AgentProcessSnapshot: Equatable, Sendable {
    let processID: Int32
    let agent: AgentKind
    let sessionID: String?
    let workingDirectory: String?
    let terminal: String?

    func candidate(now: Date = .now) -> SessionCandidate {
        let workspace = workingDirectory
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "Workspace"
        let id = sessionID ?? "process-\(agent.rawValue)-\(processID)"
        let displayName = "Claude"

        return SessionCandidate(
            id: id,
            agent: agent,
            title: workspace,
            detail: "\(displayName) session detected",
            terminal: terminal,
            projectPath: workingDirectory,
            jumpURL: nil,
            phase: .working,
            updatedAt: now,
            evidence: .process
        )
    }
}

final class LocalAgentProcessDiscovery: @unchecked Sendable {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> String?

    private let run: CommandRunner

    init(run: @escaping CommandRunner = { LocalAgentProcessDiscovery.commandOutput(executable: $0, arguments: $1) }) {
        self.run = run
    }

    func discover() -> [AgentProcessSnapshot] {
        guard let output = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="]) else { return [] }
        let processes = output.split(whereSeparator: \.isNewline).compactMap(ProcessLine.init)
        // Not uniqueKeysWithValues, which traps on a repeat: a command whose
        // arguments contain a newline splits into extra lines, and one of
        // those can parse as a process with an id already seen.
        let byID = Dictionary(processes.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var snapshots: [AgentProcessSnapshot] = []

        for process in processes.prefix(4_096) {
            guard process.tty != nil else { continue }
            let agent: AgentKind
            if Self.isClaude(command: process.command) {
                agent = .claude
            } else {
                continue
            }

            // -n and -P: no host or port name lookups. Only paths are read,
            // and a slow resolver would otherwise hold up every pass.
            let fileOutput = run("/usr/sbin/lsof", ["-n", "-P", "-a", "-p", "\(process.processID)", "-Fn"])
            let cwdOutput = run("/usr/sbin/lsof", ["-n", "-P", "-a", "-p", "\(process.processID)", "-d", "cwd", "-Fn"])
            let workingDirectory = Self.firstPath(in: cwdOutput)
            if agent == .claude,
               workingDirectory == ClaudeUsageProbe.workingDirectoryURL().path {
                continue
            }
            let transcriptPath = Self.transcriptPath(in: fileOutput, agent: agent)
            let sessionID = transcriptPath.flatMap(Self.firstUUID)
                ?? Self.sessionIDArgument(in: process.command)
            let identity = "\(agent.rawValue)|\(sessionID ?? "")|\(process.tty ?? "")|\(workingDirectory ?? "")"
            guard seen.insert(identity).inserted else { continue }

            snapshots.append(AgentProcessSnapshot(
                processID: process.processID,
                agent: agent,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                terminal: Self.terminalName(for: process, processesByID: byID)
            ))
        }

        return snapshots
    }

    /// Runs a short command (`ps`, `lsof`, `claude agents --json`) and returns
    /// its output, or nil if it fails or runs past `timeout`. Never waits
    /// forever: a hung command is terminated, then killed, so the session
    /// list keeps updating. Output is drained while the command runs, so a
    /// full pipe can never block it; stdin is closed.
    static func commandOutput(executable: String, arguments: [String], timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read as the output arrives instead of blocking a thread until end
        // of file: a descendant that inherited the pipe can hold it open long
        // after the command itself has exited.
        let output = CommandOutputBox()
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                output.append(chunk)
            }
        }
        defer { reader.readabilityHandler = nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            return nil
        }
        // The command has exited, so everything it wrote is in the pipe. End
        // of file may never come while a descendant holds the pipe; after a
        // short grace, what was read is the command's whole output.
        _ = drained.wait(timeout: .now() + 2)
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.data, encoding: .utf8)
    }


    struct ProcessLine {
        let processID: Int32
        let parentID: Int32
        let tty: String?
        let command: String

        init?(_ line: Substring) {
            let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard fields.count == 4,
                  let processID = Int32(fields[0]),
                  let parentID = Int32(fields[1]) else { return nil }
            self.processID = processID
            self.parentID = parentID
            let rawTTY = String(fields[2])
            tty = rawTTY == "??" || rawTTY == "?" || rawTTY == "-" ? nil : rawTTY
            command = String(fields[3])
        }
    }

    /// Our helper runs as `…/overhead hook claude …`, so it looks like a Claude
    /// process. Match the helper invocation, not the bare word: "overhead" is
    /// common enough to appear in the path of a real Claude process.
    private static func isOwnHelper(_ value: String) -> Bool {
        value.contains("overhead hook ")
    }

    private static func isClaude(command: String) -> Bool {
        let value = command.lowercased()
        guard !isOwnHelper(value) else { return false }
        return value == "claude"
            || value.hasPrefix("claude ")
            || value.contains("/claude ")
            || value.hasSuffix("/claude")
    }

    private static func firstPath(in output: String?) -> String? {
        output?.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.hasPrefix("/") ? path : nil
        }.first
    }

    private static func transcriptPath(in output: String?, agent: AgentKind) -> String? {
        let fragment = "/.claude/projects/"
        return output?.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.contains(fragment), path.hasSuffix(".jsonl") else { return nil }
            return path
        }.last
    }

    private static func firstUUID(in value: String) -> String? {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range, in: value) else { return nil }
        return String(value[range]).lowercased()
    }

    private static func sessionIDArgument(in command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for flag in ["--resume", "--session-id", "--session"] {
            guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else { continue }
            if let id = firstUUID(in: tokens[index + 1]) { return id }
        }
        return nil
    }

    private static func terminalName(
        for process: ProcessLine,
        processesByID: [Int32: ProcessLine]
    ) -> String? {
        var parentID = process.parentID
        var visited = Set<Int32>()
        while parentID > 1, visited.insert(parentID).inserted,
              let parent = processesByID[parentID] {
            let command = parent.command.lowercased()
            if command.contains("ghostty.app") { return "Ghostty" }
            if command.contains("terminal.app") { return "Terminal" }
            if command.contains("iterm.app") { return "iTerm" }
            if command.contains("warp.app") { return "Warp" }
            if command.contains("wezterm") { return "WezTerm" }
            if command.contains("cursor.app") { return "Cursor" }
            if command.contains("visual studio code.app") { return "VS Code" }
            parentID = parent.parentID
        }
        return nil
    }
}

final class LocalTranscriptDiscovery: @unchecked Sendable {
    private static let coldStartHeadByteCount = 128 * 1_024
    private static let coldStartTailByteCount = 2 * 1_024 * 1_024

    private let homeURL: URL
    private let fileManager: FileManager
    private let maximumAge: TimeInterval
    private let maximumFilesPerProvider: Int
    /// How many transcripts keep their scan state: the files of a pass and
    /// room for a few that dropped out of it (`TranscriptCacheRetention`).
    private var maximumCachedFiles: Int { maximumFilesPerProvider * 4 }
    private var cursors: [String: TranscriptCursor] = [:]
    /// The latest insights per session, read by the same pass that finds sessions.
    private var insightsBySessionID: [String: TranscriptInsights] = [:]
    /// Which file the insights came from. A session moved between projects
    /// has a transcript in each; the most recently written one is current.
    private var insightsSource: [String: TranscriptSourcePreference.Source] = [:]
    /// When each scanned file was last seen written, so the fast tail only
    /// watches transcripts that are actually being written.
    private var modifiedAtByPath: [String: Date] = [:]

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        maximumAge: TimeInterval = 86_400,
        maximumFilesPerProvider: Int = 12
    ) {
        self.homeURL = homeURL
        self.fileManager = fileManager
        self.maximumAge = maximumAge
        self.maximumFilesPerProvider = maximumFilesPerProvider
    }

    func discover(
        now: Date = .now,
        maximumFilesPerProvider requestedLimit: Int? = nil
    ) -> [SessionCandidate] {
        let claudeRoot = homeURL.appendingPathComponent(".claude/projects", isDirectory: true)
        let fileLimit = max(0, min(requestedLimit ?? maximumFilesPerProvider, maximumFilesPerProvider))
        let claude = discover(
            root: claudeRoot,
            now: now,
            maximumFiles: fileLimit,
            shouldInclude: { !$0.path.contains("/subagents/") }
        )
        return newestBySessionID(claude)
    }

    private func discover(
        root: URL,
        now: Date,
        maximumFiles: Int,
        shouldInclude: (URL) -> Bool
    ) -> [SessionCandidate] {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        let cutoff = now.addingTimeInterval(-maximumAge)
        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", shouldInclude(url),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff else { continue }
            files.append((url, modifiedAt))
        }

        let selected = files.sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumFiles)
        let candidates = selected.compactMap { scan($0.url, modifiedAt: $0.modifiedAt) }
        forgetStaleFiles(keeping: Set(selected.map(\.url.path)))
        return candidates
    }

    /// Drops the scan state of transcripts that left the pass long enough
    /// ago, so the caches stay bounded however long the app runs. A dropped
    /// file that is written again starts over with a fresh bounded scan.
    private func forgetStaleFiles(keeping selected: Set<String>) {
        let evicted = TranscriptCacheRetention.pathsToEvict(
            cached: modifiedAtByPath,
            selected: selected,
            capacity: maximumCachedFiles
        )
        guard !evicted.isEmpty else { return }
        for path in evicted {
            cursors.removeValue(forKey: path)
            modifiedAtByPath.removeValue(forKey: path)
        }
        for (id, source) in insightsSource where evicted.contains(source.path) {
            insightsSource.removeValue(forKey: id)
            insightsBySessionID.removeValue(forKey: id)
        }
    }

    private func scan(
        _ url: URL,
        modifiedAt: Date
    ) -> SessionCandidate? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let key = url.path
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let existingCursor = cursors[key]
        let needsColdStart = existingCursor == nil
            || fileSize < (existingCursor?.offset ?? 0)
        var cursor: TranscriptCursor
        if needsColdStart {
            cursor = TranscriptCursor(scanner: PrivacySafeSessionMetadataScanner(), insights: TranscriptInsightsScanner())
            scanColdStart(handle, fileSize: fileSize, cursor: &cursor)
        } else if let existingCursor {
            cursor = existingCursor
            scanAppendedBytes(handle, cursor: &cursor)
        } else {
            return nil
        }
        let candidate = cursor.scanner.candidate(
            transcriptPath: url.path,
            fallbackUpdatedAt: modifiedAt
        )
        cursors[key] = cursor
        modifiedAtByPath[key] = modifiedAt
        if let id = candidate?.id {
            let source = TranscriptSourcePreference.Source(path: key, modifiedAt: modifiedAt)
            if TranscriptSourcePreference.shouldReplace(insightsSource[id], with: source) {
                insightsSource[id] = source
                insightsBySessionID[id] = cursor.insights.insights
            }
        }
        return candidate
    }

    private func scanColdStart(
        _ handle: FileHandle,
        fileSize: UInt64,
        cursor: inout TranscriptCursor
    ) {
        let headByteCount = Self.coldStartHeadByteCount
        let tailByteCount = Self.coldStartTailByteCount
        let boundedByteCount = UInt64(headByteCount + tailByteCount)

        if fileSize <= boundedByteCount {
            try? handle.seek(toOffset: 0)
            scanAppendedBytes(handle, cursor: &cursor)
            return
        }

        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: headByteCount), !head.isEmpty {
            cursor.offset = UInt64(head.count)
            consumeCompleteLines(head, cursor: &cursor)
            // The rest of this line lies in the intentionally skipped middle.
            cursor.buffer.removeAll(keepingCapacity: true)
        }

        let tailOffset = fileSize - UInt64(tailByteCount)
        try? handle.seek(toOffset: tailOffset)
        guard var tail = try? handle.read(upToCount: tailByteCount), !tail.isEmpty else {
            cursor.offset = fileSize
            return
        }
        cursor.offset = fileSize

        // The tail normally starts partway through a JSONL record. Discard
        // only that incomplete record, then retain an incomplete final record
        // so the next incremental read can finish it.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail.removeSubrange(...newline)
            consumeCompleteLines(tail, cursor: &cursor)
        }
    }

    private func scanAppendedBytes(
        _ handle: FileHandle,
        cursor: inout TranscriptCursor
    ) {
        try? handle.seek(toOffset: cursor.offset)
        while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            cursor.offset += UInt64(chunk.count)
            consumeCompleteLines(chunk, cursor: &cursor)
        }
    }

    private func consumeCompleteLines(
        _ data: Data,
        cursor: inout TranscriptCursor
    ) {
        cursor.buffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let index = cursor.buffer.firstIndex(of: newline) {
            let line = Data(cursor.buffer.prefix(upTo: index))
            cursor.buffer.removeSubrange(...index)
            cursor.scanner.consume(line: line)
            cursor.insights.consume(line: line)
        }
        // Large Write results still carry the file paths receipts need, so
        // allow the insights scanner's larger line limit before dropping.
        if cursor.buffer.count > TranscriptInsightsScanner.maximumLineBytes {
            cursor.buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Insights for the sessions the last `discover()` saw. Call it from the
    /// same task, right after `discover()`, like the candidates themselves.
    func latestInsights() -> [String: TranscriptInsights] { insightsBySessionID }

    /// What a fast pass found: the sessions whose transcripts grew.
    struct Refresh: Sendable {
        var candidates: [SessionCandidate]
        var insights: [String: TranscriptInsights]
    }

    /// Transcripts written to in the last `window`, read on from where the
    /// last pass stopped. Costs one stat per such file; bytes are read only
    /// when a file grew, and a file that shrank (rewritten or rotated) gets a
    /// fresh cold start. `nil` when nothing changed. Like `discover()`, call
    /// it only from the monitor task, never concurrently with it.
    func refreshActive(now: Date = .now, window: TimeInterval = 10 * 60) -> Refresh? {
        var candidates: [SessionCandidate] = []
        var insights: [String: TranscriptInsights] = [:]
        for (path, lastModified) in modifiedAtByPath where now.timeIntervalSince(lastModified) <= window {
            guard let cursor = cursors[path] else { continue }
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  UInt64(size) != cursor.offset else { continue }
            guard let candidate = scan(url, modifiedAt: values.contentModificationDate ?? now) else { continue }
            candidates.append(candidate)
            insights[candidate.id] = insightsBySessionID[candidate.id]
        }
        guard !candidates.isEmpty else { return nil }
        return Refresh(candidates: newestBySessionID(candidates), insights: insights)
    }

    private func newestBySessionID(_ candidates: [SessionCandidate]) -> [SessionCandidate] {
        var byID: [String: SessionCandidate] = [:]
        for candidate in candidates {
            if let existing = byID[candidate.id], existing.updatedAt >= candidate.updatedAt { continue }
            byID[candidate.id] = candidate
        }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private struct TranscriptCursor {
        var scanner: PrivacySafeSessionMetadataScanner
        var insights: TranscriptInsightsScanner
        var buffer = Data()
        var offset: UInt64 = 0
    }
}

final class LocalSessionRegistry: @unchecked Sendable {
    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Overhead", isDirectory: true)
            .appendingPathComponent("sessions.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load(now: Date = .now) -> [SessionCandidate] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.iso8601.decode(RegistryFile.self, from: data),
              decoded.version == 1 else { return [] }
        let cutoff = now.addingTimeInterval(-86_400)
        return decoded.sessions
            .filter { $0.updatedAt >= cutoff }
            .map { $0.normalizedForCache() }
    }

    func save(_ sessions: [AgentSession]) throws {
        let cutoff = Date.now.addingTimeInterval(-86_400)
        let candidates = sessions.filter { $0.updatedAt >= cutoff }.prefix(40).map { session in
            SessionCandidate(
                id: session.id,
                agent: session.agent,
                title: session.title,
                titleKind: session.titleKind,
                detail: Self.safeDetail(for: session.phase),
                model: session.model,
                terminal: session.terminal,
                projectPath: session.projectPath,
                jumpURL: session.jumpURL,
                phase: session.phase,
                updatedAt: session.updatedAt,
                evidence: .cache
            ).normalizedForCache()
        }
        let data = try JSONEncoder.iso8601.encode(RegistryFile(version: 1, sessions: Array(candidates)))
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func safeDetail(for phase: SessionPhase) -> String {
        switch phase {
        case .working: "Working"
        case .waitingForApproval: "Waiting for approval"
        case .waitingForAnswer: "Waiting for input"
        case .completed: "Turn complete"
        case .failed: "Turn stopped"
        }
    }

    private struct RegistryFile: Codable {
        let version: Int
        let sessions: [SessionCandidate]
    }
}

@MainActor
final class LocalSessionRuntime {
    var onCandidate: ((SessionCandidate) -> Void)?
    var onSessionEnded: ((String) -> Void)?
    var onInitialScanCompleted: (() -> Void)?
    /// Context, cache, activity, agents, branch, PRs and cost per session.
    var onInsights: (([String: TranscriptInsights]) -> Void)?

    private let processDiscovery: LocalAgentProcessDiscovery
    private let transcriptDiscovery: LocalTranscriptDiscovery
    private let registry: LocalSessionRegistry
    private var monitorTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var trackedProcessSessionIDs = Set<String>()
    private var missedProcessCounts: [String: Int] = [:]
    private var trackedTranscriptSessionIDs = Set<String>()
    private var missedTranscriptCounts: [String: Int] = [:]

    init(
        processDiscovery: LocalAgentProcessDiscovery = LocalAgentProcessDiscovery(),
        transcriptDiscovery: LocalTranscriptDiscovery = LocalTranscriptDiscovery(),
        registry: LocalSessionRegistry = LocalSessionRegistry()
    ) {
        self.processDiscovery = processDiscovery
        self.transcriptDiscovery = transcriptDiscovery
        self.registry = registry
    }

    func start() {
        guard monitorTask == nil else { return }
        let processDiscovery = self.processDiscovery
        let transcriptDiscovery = self.transcriptDiscovery
        let registry = self.registry

        monitorTask = Task { [weak self] in
            // The persisted registry is intentionally small and privacy-safe.
            // Restore it before the first transcript traversal so an expensive
            // JSONL scan cannot hold otherwise-usable session rows off screen.
            let cache = await Task.detached(priority: .utility) {
                registry.load()
            }.value
            guard !Task.isCancelled, let self else { return }
            applyCachedSessions(cache)

            // Publish the newest transcript from each provider first. This
            // covers the active-session cold-start case without waiting for
            // the broader recent-history enrichment pass.
            let processTask = Task.detached(priority: .utility) {
                processDiscovery.discover()
            }
            let (quickTranscripts, quickInsights) = await Task.detached(priority: .utility) {
                (transcriptDiscovery.discover(maximumFilesPerProvider: 1), transcriptDiscovery.latestInsights())
            }.value
            guard !Task.isCancelled else {
                processTask.cancel()
                return
            }
            reconcileTranscripts(quickTranscripts, processes: [])
            onInsights?(quickInsights)
            onInitialScanCompleted?()

            let processes = await processTask.value
            guard !Task.isCancelled else { return }
            applyProcesses(processes, enrichingWith: cache + quickTranscripts)

            let (transcripts, insights) = await Task.detached(priority: .utility) {
                (transcriptDiscovery.discover(), transcriptDiscovery.latestInsights())
            }.value
            guard !Task.isCancelled else { return }
            reconcileTranscripts(transcripts, processes: processes)
            onInsights?(insights)

            // A full pass (process list and every recent transcript) every
            // 8 s; in between, a fast tail of the transcripts being written,
            // so the activity feed follows Claude within about a second. The
            // passes run one after another, never at the same time.
            let clock = ContinuousClock()
            var lastFullPass = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if clock.now - lastFullPass < .seconds(8) {
                    let refresh = await Task.detached(priority: .userInitiated) {
                        transcriptDiscovery.refreshActive()
                    }.value
                    guard !Task.isCancelled else { return }
                    if let refresh { applyRefresh(refresh) }
                    continue
                }
                lastFullPass = clock.now
                let transcriptTask = Task.detached(priority: .utility) {
                    (transcriptDiscovery.discover(), transcriptDiscovery.latestInsights())
                }
                let processes = await Task.detached(priority: .utility) {
                    processDiscovery.discover()
                }.value
                guard !Task.isCancelled else {
                    transcriptTask.cancel()
                    return
                }
                reconcileProcesses(processes)

                let (transcripts, insights) = await transcriptTask.value
                guard !Task.isCancelled else { return }
                reconcileTranscripts(transcripts, processes: processes)
                onInsights?(insights)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
    }

    func persist(_ sessions: [AgentSession]) {
        persistenceTask?.cancel()
        let registry = self.registry
        persistenceTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? registry.save(sessions)
        }
    }

    /// Only sessions already on screen take fast updates. New ones, and
    /// ending ones, stay with the full pass that can tell them apart.
    private func applyRefresh(_ refresh: LocalTranscriptDiscovery.Refresh) {
        for candidate in refresh.candidates where trackedTranscriptSessionIDs.contains(candidate.id) {
            missedTranscriptCounts[candidate.id] = 0
            onCandidate?(candidate)
        }
        let tracked = refresh.insights.filter { trackedTranscriptSessionIDs.contains($0.key) }
        if !tracked.isEmpty { onInsights?(tracked) }
    }

    private func applyCachedSessions(_ candidates: [SessionCandidate]) {
        for candidate in candidates where isVisible(candidate, activeProcessIDs: []) {
            trackedTranscriptSessionIDs.insert(candidate.id)
            missedTranscriptCounts[candidate.id] = 0
            onCandidate?(candidate)
        }
    }

    private func applyProcesses(
        _ processes: [AgentProcessSnapshot],
        enrichingWith candidates: [SessionCandidate]
    ) {
        var candidatesByID: [String: SessionCandidate] = [:]
        for candidate in candidates {
            if let existing = candidatesByID[candidate.id], existing.updatedAt > candidate.updatedAt {
                continue
            }
            candidatesByID[candidate.id] = candidate
        }
        for process in processes {
            let processCandidate = process.candidate()
            let id = processCandidate.id
            trackedProcessSessionIDs.insert(id)
            missedProcessCounts[id] = 0
            if var candidate = candidatesByID[id] {
                candidate.evidence = .process
                candidate.jumpURL = candidate.jumpURL ?? processCandidate.jumpURL
                candidate.projectPath = candidate.projectPath ?? processCandidate.projectPath
                onCandidate?(candidate)
            } else {
                onCandidate?(processCandidate)
            }
        }
    }

    private func reconcileProcesses(_ processes: [AgentProcessSnapshot]) {
        let observed = Set(processes.map { $0.candidate().id })
        for process in processes {
            let candidate = process.candidate()
            if trackedProcessSessionIDs.insert(candidate.id).inserted {
                onCandidate?(candidate)
            }
            missedProcessCounts[candidate.id] = 0
        }

        for id in Array(trackedProcessSessionIDs) where !observed.contains(id) {
            let misses = (missedProcessCounts[id] ?? 0) + 1
            missedProcessCounts[id] = misses
            guard misses >= 2 else { continue }
            trackedProcessSessionIDs.remove(id)
            missedProcessCounts.removeValue(forKey: id)
            onSessionEnded?(id)
        }
    }

    private func reconcileTranscripts(
        _ candidates: [SessionCandidate],
        processes: [AgentProcessSnapshot]
    ) {
        let activeProcessIDs = Set(processes.map { $0.candidate().id })
        let visible = candidates.filter { isVisible($0, activeProcessIDs: activeProcessIDs) }
        let observed = Set(visible.map(\.id))

        for candidate in visible {
            trackedTranscriptSessionIDs.insert(candidate.id)
            missedTranscriptCounts[candidate.id] = 0
            onCandidate?(candidate)
        }

        for id in Array(trackedTranscriptSessionIDs)
        where !observed.contains(id) && !activeProcessIDs.contains(id) {
            let misses = (missedTranscriptCounts[id] ?? 0) + 1
            missedTranscriptCounts[id] = misses
            guard misses >= 2 else { continue }
            trackedTranscriptSessionIDs.remove(id)
            missedTranscriptCounts.removeValue(forKey: id)
            onSessionEnded?(id)
        }
    }

    private func isVisible(
        _ candidate: SessionCandidate,
        activeProcessIDs: Set<String>,
        now: Date = .now
    ) -> Bool {
        SessionDiscoveryRetentionPolicy.shouldRetain(
            phase: candidate.phase,
            updatedAt: candidate.updatedAt,
            hasActiveProcess: activeProcessIDs.contains(candidate.id),
            hasLastResponse: candidate.latestAgentResponse != nil,
            now: now
        )
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The command's output so far. The pipe's reader appends on its own queue
/// while the caller waits, so every access takes the lock.
private final class CommandOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var data: Data { lock.withLock { buffer } }

    func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }
}

