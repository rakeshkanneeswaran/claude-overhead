import Foundation
import Testing
@testable import ChimloCore

@Suite("Session receipts and daily recaps")
struct ReceiptAndRecapTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: Receipts

    @Test("Without git, files and line totals come from the record")
    func receiptWithoutGit() {
        var record = sessionRecord()
        record.latestUserPrompt = String(repeating: "word ", count: 100)
        record.filesChanged = ["Sources/Client.swift", "Tests/ClientTests.swift"]
        record.linesAdded = 40
        record.linesRemoved = 6

        let receipt = SessionReceiptBuilder.build(record: record, git: nil)

        #expect(!receipt.usesGit)
        #expect(receipt.files == [
            ReceiptFileChange(path: "Sources/Client.swift"),
            ReceiptFileChange(path: "Tests/ClientTests.swift"),
        ])
        #expect(receipt.insertions == 40)
        #expect(receipt.deletions == 6)
        #expect(receipt.commits.isEmpty)
        #expect(receipt.branch == "feature/retries")
        #expect(receipt.request?.count == SessionReceipt.requestPreviewLength)
        #expect(receipt.request?.hasSuffix("\u{2026}") == true)
        #expect(receipt.summary == nil)
        #expect(receipt.duration == 3_900)

        let unknownTotals = SessionReceiptBuilder.build(record: sessionRecord(), git: nil)
        #expect(unknownTotals.insertions == nil)
        #expect(unknownTotals.deletions == nil)
    }

    @Test("With git, files, commits, totals and branch come from git")
    func receiptWithGit() {
        var record = sessionRecord()
        record.filesChanged = ["ignored-when-git-is-given.swift"]
        record.linesAdded = 999
        let git = ReceiptGitInput(
            branch: "feature/retries-v2",
            files: [
                ReceiptFileChange(path: "Sources/Client.swift", added: 10, removed: 2),
                ReceiptFileChange(path: "Assets/logo.png"),
            ],
            commits: [ReceiptCommit(sha: "0123456789abcdef", subject: "Add retry policy")],
            insertions: 10,
            deletions: 2
        )

        let receipt = SessionReceiptBuilder.build(record: record, git: git)

        #expect(receipt.usesGit)
        #expect(receipt.files == git.files)
        #expect(receipt.commits == git.commits)
        #expect(receipt.insertions == 10)
        #expect(receipt.deletions == 2)
        #expect(receipt.branch == "feature/retries-v2")

        let empty = SessionReceiptBuilder.build(record: record, git: ReceiptGitInput())
        #expect(empty.insertions == 0)
        #expect(empty.files.isEmpty)
        #expect(empty.branch == "feature/retries")
    }

    @Test("Share text lists the session facts and only includes previews that exist")
    func shareText() {
        var record = sessionRecord()
        record.tests = [HistoryTestRun(command: "make test", outcome: HistoryTestRun.passed)]
        record.agents = [
            HistoryAgent(id: "a1", type: "Explore", description: "Map the client"),
            HistoryAgent(id: "a2", failed: true),
        ]
        record.pullRequests = [HistoryPullRequest(number: 12, url: "https://example.invalid/pr/12", repository: "example/alpha")]
        record.costUSD = 2.5
        let git = ReceiptGitInput(
            files: [
                ReceiptFileChange(path: "Sources/Client.swift", added: 10, removed: 2),
                ReceiptFileChange(path: "Assets/logo.png"),
            ],
            commits: [ReceiptCommit(sha: "0123456789abcdef", subject: "Add retry policy")],
            insertions: 10,
            deletions: 2
        )

        let text = SessionReceiptBuilder.build(record: record, git: git).shareText
        let modelName = ModelDisplayName.resolve(modelID: "claude-opus-4-1", agent: .claude) ?? "claude-opus-4-1"
        let expected = [
            "Add retries to the client",
            "alpha - Completed",
            "Duration: 1h 05m",
            "Model: \(modelName)",
            "Branch: feature/retries",
            "Changes: 2 files, +10 / -2",
            "  Sources/Client.swift +10 / -2",
            "  Assets/logo.png",
            "Commits:",
            "  0123456 Add retry policy",
            "Tests:",
            "  make test: passed",
            "Agents:",
            "  Explore: Map the client",
            "  Agent (failed)",
            "Pull requests:",
            "  example/alpha #12 https://example.invalid/pr/12",
        ].joined(separator: "\n")
        #expect(text == expected)
        #expect(!text.contains("Request:"))
        #expect(!text.contains("$"))

        record.latestUserPrompt = "Add retries\n\nwith backoff"
        record.latestAgentResponse = "Added a retry policy."
        let withPreviews = SessionReceiptBuilder.build(record: record, git: nil).shareText
        #expect(withPreviews.contains("Request: Add retries with backoff"))
        #expect(withPreviews.contains("Summary: Added a retry policy."))
    }

    // MARK: Daily recaps

    @Test("Recap counts outcomes by end time and totals the day's sessions")
    func recapCounts() throws {
        let calendar = utcCalendar
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let midnight = calendar.startOfDay(for: day)
        func at(_ hours: Double) -> Date { midnight.addingTimeInterval(hours * 3_600) }

        var first = dayRecord("first", project: "alpha", from: at(9), to: at(10), status: .completed)
        first.filesChanged = ["a.swift", "b.swift"]
        first.linesAdded = 10
        first.linesRemoved = 2
        first.costUSD = 1.25
        first.agents = [
            HistoryAgent(id: "x", startedAt: at(9.5)),
            HistoryAgent(id: "y"),
            HistoryAgent(id: "z", startedAt: at(-3)),
        ]
        var second = dayRecord("second", project: "beta", from: at(11), to: at(12), status: .completed)
        second.filesChanged = ["a.swift"]
        second.linesAdded = 5
        second.linesRemoved = 1
        let overnight = dayRecord("overnight", project: "alpha", from: at(-1), to: at(0.5), status: .completed)
        let failed = dayRecord("failed", project: "alpha", from: at(13), to: at(14), status: .failed)
        let interrupted = dayRecord("interrupted", project: "beta", from: at(15), to: at(16), status: .interrupted)
        let finishesTomorrow = dayRecord("late", project: "gamma", from: at(23), to: at(25), status: .completed)
        let yesterday = dayRecord("yesterday", project: "delta", from: at(-10), to: at(-9), status: .completed)

        let recap = DailyRecapBuilder.build(
            records: [first, second, overnight, failed, interrupted, finishesTomorrow, yesterday],
            day: day,
            calendar: calendar,
            github: RecapGitHubInput(pullRequestsOpened: 1, pullRequestsMerged: 2, ciFailures: 1)
        )

        #expect(recap.day == midnight)
        #expect(recap.sessionsCompleted == 3)
        #expect(recap.sessionsFailed == 1)
        #expect(recap.sessionsInterrupted == 1)
        #expect(recap.projects == ["gamma", "beta", "alpha"])
        #expect(recap.agentsUsed == 2)
        #expect(recap.filesChanged == 3)
        #expect(recap.linesAdded == 15)
        #expect(recap.linesRemoved == 3)
        #expect(recap.costUSD == 1.25)
        #expect(!recap.isEmpty)
        #expect(recap.highlights == [
            "Completed 3 sessions across 2 projects.",
            "1 session failed.",
            "1 session was interrupted.",
            "Changed 3 files (+15 / -3).",
            "Ran 2 agents.",
            "Opened 1 pull request.",
            "Merged 2 pull requests.",
            "1 CI run failed.",
            "Reported cost: $1.25.",
        ])
        #expect(recap.highlights.allSatisfy { !$0.contains("!") })
    }

    @Test("A single-project day names the project; an idle day is empty")
    func recapSingleProjectAndEmpty() throws {
        let calendar = utcCalendar
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
        let only = dayRecord("only", project: "alpha", from: day.addingTimeInterval(3_600), to: day.addingTimeInterval(7_200), status: .completed)
        let running = dayRecord("running", project: "alpha", from: day.addingTimeInterval(8_000), to: day.addingTimeInterval(9_000), status: .running)

        let single = DailyRecapBuilder.build(records: [only, running], day: day, calendar: calendar)
        #expect(single.highlights == ["Completed 1 session in alpha."])
        #expect(single.linesAdded == nil)
        #expect(single.costUSD == nil)

        let workingOnly = DailyRecapBuilder.build(records: [running], day: day, calendar: calendar)
        #expect(workingOnly.highlights == ["Worked in alpha."])
        #expect(!workingOnly.isEmpty)

        let nextWeek = day.addingTimeInterval(7 * 86_400)
        let empty = DailyRecapBuilder.build(records: [only, running], day: nextWeek, calendar: calendar)
        #expect(empty.isEmpty)
        #expect(empty.highlights.isEmpty)
        #expect(empty.projects.isEmpty)

        let quietGitHub = DailyRecapBuilder.build(records: [], day: nextWeek, calendar: calendar, github: RecapGitHubInput())
        #expect(quietGitHub.isEmpty)
        let busyGitHub = DailyRecapBuilder.build(records: [], day: nextWeek, calendar: calendar, github: RecapGitHubInput(reviewsWaiting: 2))
        #expect(!busyGitHub.isEmpty)
        #expect(busyGitHub.highlights == ["2 reviews are waiting."])
    }

    // MARK: Fixtures

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    private func sessionRecord() -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: "session-1",
            projectPath: "/workspace/alpha",
            projectName: "alpha",
            title: "Add retries to the client",
            startedAt: base,
            lastActivityAt: base.addingTimeInterval(4_000),
            status: .completed,
            endedAt: base.addingTimeInterval(3_900),
            model: "claude-opus-4-1",
            gitBranch: "feature/retries"
        )
    }

    private func dayRecord(_ id: String, project: String, from: Date, to: Date, status: HistoryStatus) -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: id,
            projectPath: "/workspace/\(project)",
            projectName: project,
            title: "Session \(id)",
            startedAt: from,
            lastActivityAt: to,
            status: status,
            endedAt: status.isActive ? nil : to
        )
    }
}
