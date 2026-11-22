import Foundation
import Testing
@testable import ChimloCore

@Suite("Project pulse and timeline")
struct SessionHistoryProjectTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Pulses group by path, fall back to name, and sort attention, active, then recency")
    func pulseGroupingAndSorting() {
        var alphaDone = record("alpha-done", path: "/workspace/alpha", name: "alpha", at: 10, status: .completed)
        alphaDone.gitBranch = "main"
        alphaDone.pullRequests = [HistoryPullRequest(number: 4, url: "https://example.invalid/pr/4", repository: "example/alpha")]
        var alphaLive = record("alpha-live", path: "/workspace/alpha/", name: "alpha", at: 30, status: .running)
        alphaLive.gitBranch = "feature/pulse"
        alphaLive.pullRequests = [HistoryPullRequest(number: 4, url: "https://example.invalid/pr/4", repository: "example/alpha")]
        let alphaFailed = record("alpha-failed", path: "/workspace/alpha", name: "alpha", at: 20, status: .failed)
        let betaWaiting = record("beta-waiting", path: "/workspace/beta", name: "beta", at: 5, status: .waiting)
        let gammaDone = record("gamma-done", path: nil, name: "gamma", at: 50, status: .completed)
        let deltaOld = record("delta-old", path: "/workspace/delta", name: "", at: 1, status: .completed)

        let pulses = ProjectPulseBuilder.build(
            records: [alphaDone, alphaLive, alphaFailed, betaWaiting, gammaDone, deltaOld],
            liveSessionIDs: ["alpha-live", "beta-waiting"],
            attentionSessionIDs: ["beta-waiting"]
        )

        #expect(pulses.map(\.projectKey) == ["/workspace/beta", "/workspace/alpha", "gamma", "/workspace/delta"])
        #expect(pulses[0].attentionSessionIDs == ["beta-waiting"])

        let alpha = pulses[1]
        #expect(alpha.name == "alpha")
        #expect(alpha.branch == "feature/pulse")
        #expect(alpha.activeSessionIDs == ["alpha-live"])
        #expect(alpha.attentionSessionIDs.isEmpty)
        #expect(alpha.recentCompleted.map(\.id) == ["alpha-done"])
        #expect(alpha.recentFailed.map(\.id) == ["alpha-failed"])
        #expect(alpha.lastActivityAt == base.addingTimeInterval(30))
        #expect(alpha.linkedPullRequests.count == 1)

        #expect(pulses[2].path == nil)
        #expect(pulses[3].name == "delta")
    }

    @Test("Recent lists are newest first and respect the limit")
    func pulseRecentLimit() {
        let records = (0..<8).map { index in
            record("done-\(index)", path: "/workspace/alpha", name: "alpha", at: TimeInterval(index), status: .completed)
        }

        let pulse = ProjectPulseBuilder.build(records: records, liveSessionIDs: [], attentionSessionIDs: [], recentLimit: 3)

        #expect(pulse.count == 1)
        #expect(pulse.first?.recentCompleted.map(\.id) == ["done-7", "done-6", "done-5"])
        #expect(pulse.first?.activeSessionIDs.isEmpty == true)
    }

    @Test("Timeline is newest first and reports branch changes between sessions")
    func timelineOrderingAndBranchChanges() {
        var first = record("s1", path: "/workspace/alpha", name: "alpha", at: 600, status: .completed, startOffset: 0)
        first.gitBranch = "main"
        first.endedAt = base.addingTimeInterval(600)
        first.pullRequests = [HistoryPullRequest(number: 9, url: "https://example.invalid/pr/9", repository: "example/alpha")]
        var second = record("s2", path: "/workspace/alpha", name: "alpha", at: 1_800, status: .failed, startOffset: 1_000)
        second.gitBranch = "main"
        second.endedAt = base.addingTimeInterval(1_800)
        second.events = [HistoryEvent(kind: .compacted, at: base.addingTimeInterval(1_500), detail: "auto")]
        var third = record("s3", path: "/workspace/alpha", name: "alpha", at: 2_500, status: .running, startOffset: 2_000)
        third.gitBranch = "feature/timeline"
        let fourth = record("s4", path: "/workspace/alpha", name: "alpha", at: 3_500, status: .interrupted, startOffset: 3_000)
        var fifth = record("s5", path: "/workspace/alpha", name: "alpha", at: 4_500, status: .completed, startOffset: 4_000)
        fifth.gitBranch = "feature/timeline"
        let otherProject = record("other", path: "/workspace/beta", name: "beta", at: 9_000, status: .completed, startOffset: 8_000)

        let entries = ProjectTimelineBuilder.entries(
            records: [fifth, otherProject, third, first, fourth, second],
            projectKey: "/workspace/alpha"
        )

        #expect(entries.map(\.kind) == [
            .sessionCompleted, .sessionStarted,  // s5
            .sessionStarted,                     // s4 (interrupted: no outcome)
            .sessionStarted, .branchChanged,     // s3
            .sessionFailed, .compacted, .sessionStarted,  // s2
            .sessionCompleted, .pullRequestLinked, .sessionStarted,  // s1
        ])
        #expect(entries.allSatisfy { $0.sessionID != "other" })
        #expect(Set(entries.map(\.id)).count == entries.count)

        let branchChanges = entries.filter { $0.kind == .branchChanged }
        #expect(branchChanges.count == 1)
        #expect(branchChanges.first?.sessionID == "s3")
        #expect(branchChanges.first?.title == "Switched to feature/timeline")
        #expect(branchChanges.first?.detail == "from main")

        let windowed = ProjectTimelineBuilder.entries(
            records: [first, second, third],
            projectKey: "/workspace/alpha",
            from: base.addingTimeInterval(1_000),
            to: base.addingTimeInterval(1_800)
        )
        #expect(windowed.map(\.kind) == [.sessionFailed, .compacted, .sessionStarted])
    }

    private func record(
        _ id: String,
        path: String?,
        name: String,
        at offset: TimeInterval,
        status: HistoryStatus,
        startOffset: TimeInterval? = nil
    ) -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: id,
            projectPath: path,
            projectName: name,
            title: "Session \(id)",
            startedAt: base.addingTimeInterval(startOffset ?? offset - 1),
            lastActivityAt: base.addingTimeInterval(offset),
            status: status
        )
    }
}
