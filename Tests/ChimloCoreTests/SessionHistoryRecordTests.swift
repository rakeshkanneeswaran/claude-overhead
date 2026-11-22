import Foundation
import Testing
@testable import ChimloCore

@Suite("Session history record merge")
struct SessionHistoryRecordTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Merging the same update twice equals merging it once")
    func mergeIsIdempotent() {
        let existing = record(
            agents: [HistoryAgent(id: "agent-1", type: "Explore", startedAt: base)],
            tests: [HistoryTestRun(command: "swift test", outcome: HistoryTestRun.failed)],
            events: events(count: 180, start: 0)
        )
        var update = record(lastActivity: 900, status: .completed)
        update.endedAt = base.addingTimeInterval(900)
        update.filesChanged = ["Sources/App.swift", "README.md"]
        update.agents = [HistoryAgent(id: "agent-1", description: "Map the module", finishedAt: base.addingTimeInterval(60), failed: true)]
        update.tests = [HistoryTestRun(command: "swift test", outcome: HistoryTestRun.passed)]
        // Overlapping and tied timestamps exercise the deterministic event cap.
        update.events = events(count: 120, start: 150) + [HistoryEvent(kind: .question, at: base.addingTimeInterval(150))]

        let once = existing.merged(with: update)
        let twice = once.merged(with: update)

        #expect(once == twice)
        #expect(once.events.count == SessionHistoryRecord.maxEvents)
        #expect(once.normalized() == once)
    }

    @Test("Newer non-nil scalars win while nil and empty values never erase")
    func fieldPrecedence() {
        var existing = record(lastActivity: 300, status: .running)
        existing.model = "claude-opus-4-1"
        existing.gitBranch = "main"
        existing.latestUserPrompt = "Add retries"
        existing.costUSD = 0.4
        existing.linesAdded = 3
        existing.contextPeakFraction = 0.8
        existing.endedAt = base.addingTimeInterval(500)

        var newer = SessionHistoryRecord(
            id: "session-1",
            projectPath: nil,
            projectName: "",
            title: "   ",
            startedAt: base.addingTimeInterval(-60),
            lastActivityAt: base.addingTimeInterval(200),
            status: .unknown
        )
        newer.gitBranch = "feature/retries"
        newer.costUSD = 0.9
        newer.contextPeakFraction = 0.5
        newer.endedAt = base.addingTimeInterval(400)

        let merged = existing.merged(with: newer)

        #expect(merged.startedAt == base.addingTimeInterval(-60))
        #expect(merged.lastActivityAt == base.addingTimeInterval(300))
        #expect(merged.endedAt == base.addingTimeInterval(500))
        #expect(merged.projectPath == "/workspace/alpha")
        #expect(merged.projectName == "alpha")
        #expect(merged.title == "Add retries to the client")
        #expect(merged.status == .running)
        #expect(merged.model == "claude-opus-4-1")
        #expect(merged.gitBranch == "feature/retries")
        #expect(merged.latestUserPrompt == "Add retries")
        #expect(merged.costUSD == 0.9)
        #expect(merged.linesAdded == 3)
        #expect(merged.contextPeakFraction == 0.8)

        var finished = newer
        finished.status = .completed
        #expect(existing.merged(with: finished).status == .completed)
    }

    @Test("Arrays union by identity, keep order, and merge duplicates")
    func arrayUnions() {
        var existing = record()
        existing.filesChanged = ["b.swift", "a.swift"]
        existing.agents = [HistoryAgent(id: "agent-1", type: "Explore", failed: true)]
        existing.tests = [HistoryTestRun(command: "make test", outcome: HistoryTestRun.passed)]
        existing.pullRequests = [HistoryPullRequest(number: 7, url: "https://example.invalid/pr/7", repository: "example/alpha")]

        var newer = record()
        newer.filesChanged = ["a.swift", "c.swift", "c.swift"]
        newer.agents = [
            HistoryAgent(id: "agent-2", type: "Plan"),
            HistoryAgent(id: "agent-1", description: "Survey", failed: false),
        ]
        newer.tests = [HistoryTestRun(command: "make test", outcome: HistoryTestRun.unknown)]
        newer.pullRequests = [
            HistoryPullRequest(number: 7, url: "", repository: "example/alpha"),
            HistoryPullRequest(number: 7, url: "https://example.invalid/pr/7b", repository: "example/beta"),
        ]

        let merged = existing.merged(with: newer)

        #expect(merged.filesChanged == ["b.swift", "a.swift", "c.swift"])
        #expect(merged.agents.map(\.id) == ["agent-1", "agent-2"])
        #expect(merged.agents.first == HistoryAgent(id: "agent-1", type: "Explore", description: "Survey", failed: true))
        #expect(merged.tests == [HistoryTestRun(command: "make test", outcome: HistoryTestRun.passed)])
        #expect(merged.pullRequests.count == 2)
        #expect(merged.pullRequests.first?.url == "https://example.invalid/pr/7")
    }

    @Test("Events dedupe by kind and time, sort oldest first, and keep the newest 200")
    func eventDedupeAndCap() {
        var existing = record()
        existing.events = events(count: 150, start: 0)
        var newer = record()
        newer.events = events(count: 100, start: 100)
        newer.events[0].detail = "from the newer snapshot"

        // 150 + 100 with 50 duplicates: exactly the cap, nothing dropped.
        let exact = existing.merged(with: newer)
        #expect(exact.events.count == SessionHistoryRecord.maxEvents)
        #expect(exact.events.first?.at == base)
        #expect(exact.events.last?.at == base.addingTimeInterval(199))
        #expect(exact.events[100].detail == "from the newer snapshot")

        var flood = record()
        flood.events = events(count: 260, start: 0).reversed()
        let capped = record().merged(with: flood)
        #expect(capped.events.count == 200)
        #expect(capped.events.first?.at == base.addingTimeInterval(60))
        #expect(capped.events.map(\.at) == capped.events.map(\.at).sorted())
    }

    @Test("Duration runs to the end or latest activity and is never negative")
    func duration() {
        var running = record(lastActivity: 125)
        #expect(running.duration == 125)
        running.endedAt = base.addingTimeInterval(90)
        #expect(running.duration == 90)
        running.endedAt = base.addingTimeInterval(-5)
        #expect(running.duration == nil)
    }

    @Test("Decoding tolerates missing collections, unknown statuses and unknown event kinds")
    func tolerantDecoding() throws {
        let json = """
        {
          "id": "session-9",
          "startedAt": 800000000,
          "status": "paused-by-a-future-build",
          "events": [
            {"kind": "started", "at": 800000000},
            {"kind": "teleported", "at": 800000001},
            {"kind": "completed", "at": 800000002, "detail": "done"}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(SessionHistoryRecord.self, from: Data(json.utf8))

        #expect(decoded.status == .unknown)
        #expect(decoded.lastActivityAt == decoded.startedAt)
        #expect(decoded.filesChanged.isEmpty)
        #expect(decoded.agents.isEmpty)
        #expect(decoded.events.map(\.kind) == [.started, .completed])
    }

    @Test("Encoding round-trips every field exactly")
    func codableRoundTrip() throws {
        var original = record(lastActivity: 61.25, status: .failed)
        original.endedAt = base.addingTimeInterval(61.25)
        original.model = "claude-sonnet-4-5"
        original.transcriptPath = "/workspace/.transcripts/session-1.jsonl"
        original.filesChanged = ["Package.swift"]
        original.agents = [HistoryAgent(id: "agent-1", type: "Explore", startedAt: base.addingTimeInterval(0.123))]
        original.tests = [HistoryTestRun(command: "make test", outcome: HistoryTestRun.failed)]
        original.pullRequests = [HistoryPullRequest(number: 3, url: "https://example.invalid/pr/3", repository: "example/alpha")]
        original.events = [HistoryEvent(kind: .failed, at: base.addingTimeInterval(61.25), detail: "exit 1")]
        original.contextPeakFraction = 0.42

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionHistoryRecord.self, from: data)
        #expect(decoded == original)
    }

    private func record(
        lastActivity: TimeInterval = 100,
        status: HistoryStatus = .running,
        agents: [HistoryAgent] = [],
        tests: [HistoryTestRun] = [],
        events: [HistoryEvent] = []
    ) -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: "session-1",
            projectPath: "/workspace/alpha",
            projectName: "alpha",
            title: "Add retries to the client",
            startedAt: base,
            lastActivityAt: base.addingTimeInterval(lastActivity),
            status: status,
            agents: agents,
            tests: tests,
            events: events
        )
    }

    private func events(count: Int, start: Int) -> [HistoryEvent] {
        (start..<(start + count)).map { offset in
            HistoryEvent(kind: .prompt, at: base.addingTimeInterval(TimeInterval(offset)), detail: "prompt \(offset)")
        }
    }
}
