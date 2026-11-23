import ChimloCore
import Foundation
import Testing

/// The status line reports only the 5-hour and weekly limits. Its reading
/// must not wipe the per-model limits the /usage panel found.
@Suite("Audit 1.0.7 UI: per-model usage limits")
struct Audit107UICapacityTests {
    private let probedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var reset: Date { probedAt.addingTimeInterval(3 * 86_400) }

    private func window(
        _ kind: CapacityWindowKind,
        used: Double,
        at observedAt: Date,
        source: CapacitySource,
        resetsAt: Date?,
        scope: String? = nil
    ) -> CapacityWindowSnapshot {
        CapacityWindowSnapshot(
            provider: .claude, kind: kind, usedPercentage: used, resetsAt: resetsAt,
            observedAt: observedAt, source: source, scope: scope
        )
    }

    private var probe: ProviderCapacitySnapshot {
        ProviderCapacitySnapshot(provider: .claude, windows: [
            window(.session, used: 20, at: probedAt, source: .claudeCLIUsage, resetsAt: probedAt.addingTimeInterval(3_600)),
            window(.weekly, used: 50, at: probedAt, source: .claudeCLIUsage, resetsAt: reset),
            window(.weekly, used: 80, at: probedAt, source: .claudeCLIUsage, resetsAt: reset, scope: "Fable"),
        ], observedAt: probedAt)
    }

    private func statusLine(at date: Date) -> ProviderCapacitySnapshot {
        ProviderCapacitySnapshot(provider: .claude, windows: [
            window(.session, used: 25, at: date, source: .claudeStatusLine, resetsAt: date.addingTimeInterval(3_000)),
            window(.weekly, used: 51, at: date, source: .claudeStatusLine, resetsAt: reset),
        ], observedAt: date)
    }

    @Test("A status-line reading keeps the per-model limit the panel found")
    func statusLineKeepsModelLimits() throws {
        let later = probedAt.addingTimeInterval(60)
        let merged = statusLine(at: later).keepingModelLimits(from: probe)
        // The status line's own numbers are exactly as read.
        #expect(merged.window(.session)?.usedPercentage == 25)
        #expect(merged.window(.weekly)?.usedPercentage == 51)
        #expect(merged.window(.weekly)?.source == .claudeStatusLine)
        #expect(merged.observedAt == later)
        // The model limit is still there, dated when it was really read.
        let fable = try #require(merged.window(.weekly, scope: "Fable"))
        #expect(fable.usedPercentage == 80)
        #expect(fable.observedAt == probedAt)
        #expect(CapacityRows.rows(for: merged).map(\.label) == ["7D", "5H", "FABLE"])
    }

    @Test("The model limit is kept across many status-line readings, until it resets")
    func keptUntilReset() {
        var current = probe
        for minute in 1...30 {
            current = statusLine(at: probedAt.addingTimeInterval(Double(minute) * 60)).keepingModelLimits(from: current)
            #expect(current.window(.weekly, scope: "Fable")?.usedPercentage == 80)
            #expect(current.windows.count == 3)
        }
        let afterReset = statusLine(at: reset.addingTimeInterval(1)).keepingModelLimits(from: current)
        #expect(afterReset.window(.weekly, scope: "Fable") == nil)
        #expect(afterReset.windows.count == 2)
    }

    @Test("A reading that reports the model limit itself wins, and all-model limits are never carried over")
    func newReadingWins() {
        let later = probedAt.addingTimeInterval(600)
        let newer = ProviderCapacitySnapshot(provider: .claude, windows: [
            window(.weekly, used: 55, at: later, source: .claudeCLIUsage, resetsAt: reset),
            window(.weekly, used: 91, at: later, source: .claudeCLIUsage, resetsAt: reset, scope: "fable"),
        ], observedAt: later)
        let merged = newer.keepingModelLimits(from: probe)
        #expect(merged.modelWindows.count == 1)
        #expect(merged.window(.weekly, scope: "Fable")?.usedPercentage == 91)
        // The 5-hour limit the newer reading left out is not brought back.
        #expect(merged.window(.session) == nil)
    }

    @Test("With nothing earlier, or nothing per model earlier, the reading is unchanged")
    func nothingToKeep() {
        let reading = statusLine(at: probedAt)
        #expect(reading.keepingModelLimits(from: nil) == reading)
        let later = statusLine(at: probedAt.addingTimeInterval(60))
        #expect(later.keepingModelLimits(from: reading) == later)
    }

    @Test("A kept model limit still gets re-read: its age decides when to ask Claude Code again")
    func modelLimitAgeDrivesTheProbe() {
        let later = probedAt.addingTimeInterval(CapacityPolicy.freshnessInterval + 60)
        let merged = statusLine(at: later).keepingModelLimits(from: probe)
        #expect(merged.oldestLimitObservation == probedAt)
        // Judged by the status line alone the reading is fresh…
        #expect(!CapacityPolicy.shouldProbeClaudeUsage(snapshot: merged, lastAttemptAt: nil, now: later))
        // …but the model limit is old, and only the probe can refresh it.
        #expect(CapacityPolicy.shouldProbeClaudeUsage(snapshot: merged.datedByOldestLimit, lastAttemptAt: nil, now: later))
        // Without per-model limits nothing changes.
        let plain = statusLine(at: later)
        #expect(plain.datedByOldestLimit == plain)
        #expect(!CapacityPolicy.shouldProbeClaudeUsage(snapshot: plain.datedByOldestLimit, lastAttemptAt: nil, now: later))
    }
}
