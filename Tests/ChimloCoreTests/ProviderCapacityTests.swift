import Foundation
import Testing
@testable import ChimloCore

@Suite("Provider capacity")
struct ProviderCapacityTests {
    @Test("Claude status-line data produces separate session and weekly windows")
    func parsesClaudeWindows() throws {
        let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":32,"resets_at":1700001000},"seven_day":{"used_percentage":67,"resets_at":1700090000}}}"#.utf8)
        let snapshot = try #require(ProviderCapacityParser.claudeStatusLine(data))

        #expect(snapshot.window(.session)?.remainingPercentage == 68)
        #expect(snapshot.window(.weekly)?.remainingPercentage == 33)
    }

    @Test("Claude utilization payload produces session and weekly windows")
    func parsesClaudeUtilizationWindows() throws {
        let data = Data(#"{"rate_limits":{"five_hour":{"utilization":36,"resets_at":"2026-07-22T07:39:59.633009+00:00"},"seven_day":{"utilization":4,"resets_at":"2026-07-27T13:59:59.633030+00:00"}}}"#.utf8)
        let snapshot = try #require(ProviderCapacityParser.claudeStatusLine(data))

        #expect(snapshot.window(.session)?.remainingPercentage == 64)
        #expect(snapshot.window(.weekly)?.remainingPercentage == 96)
        #expect(snapshot.window(.session)?.resetsAt != nil)
        #expect(snapshot.window(.weekly)?.resetsAt != nil)
    }

    @Test("Missing capacity is unavailable rather than zero")
    func missingDataIsUnavailable() {
        #expect(ProviderCapacityParser.claudeStatusLine(Data(#"{"rate_limits":{}}"#.utf8)) == nil)
        #expect(ProviderCapacityParser.claudeUsagePanel("No usage data here") == nil)
    }

    @Test("Claude usage panel parses provider-reported remaining percentages")
    func parsesClaudeUsagePanel() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let output = """
        \u{001B}[2JSettings: Usage

        Current session
        ███████░░░ 72% left
        Resets in 2 hr 14 min

        Current week (all models)
        ████░░░░░░ 41% left
        Resets Monday at 6:30 PM
        \u{001B}[0m
        """

        let snapshot = try #require(
            ProviderCapacityParser.claudeUsagePanel(output, observedAt: observedAt)
        )

        #expect(snapshot.window(.session)?.usedPercentage == 28)
        #expect(snapshot.window(.weekly)?.usedPercentage == 59)
        #expect(
            snapshot.window(.session)?.resetsAt
                == observedAt.addingTimeInterval((2 * 60 + 14) * 60)
        )
        #expect(snapshot.window(.session)?.source == .claudeCLIUsage)
        #expect(snapshot.window(.weekly)?.source == .claudeCLIUsage)
        #expect(snapshot.observedAt == observedAt)
    }

    @Test("Claude usage panel parses local reset timestamps")
    func parsesClaudeLocalResetTimestamps() throws {
        let timeZone = try #require(TimeZone(identifier: "Asia/Calcutta"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let observedAt = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 22,
            hour: 12
        )))
        let output = """
        Settings  Status  Config  Usage  Stats
        Current session
        0% used
        Resets 6:39pm (Asia/Calcutta)
        Current week (all models)
        10% used
        Resets Jul 27 at 7:29pm (Asia/Calcutta)
        """

        let snapshot = try #require(
            ProviderCapacityParser.claudeUsagePanel(output, observedAt: observedAt)
        )
        let expectedSessionReset = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 22,
            hour: 18,
            minute: 39
        )))
        let expectedWeeklyReset = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 27,
            hour: 19,
            minute: 29
        )))

        #expect(snapshot.window(.session)?.resetsAt == expectedSessionReset)
        #expect(snapshot.window(.weekly)?.resetsAt == expectedWeeklyReset)
    }

    @Test("Claude usage parser ignores stale terminal fragments before the latest panel")
    func ignoresEarlierTerminalFragments() throws {
        let output = """
        Current session 0% left
        Current week (all models) 0% left
        some redraw noise
        Settings: Usage
        Current session 65% left
        Current week (all models) 20% left
        """

        let snapshot = try #require(ProviderCapacityParser.claudeUsagePanel(output))

        #expect(snapshot.window(.session)?.remainingPercentage == 65)
        #expect(snapshot.window(.weekly)?.remainingPercentage == 20)
    }

    @Test("Claude 2.1 usage panel parses used percentages across partial redraws")
    func parsesCurrentClaudeUsedPercentages() throws {
        let output = """
        Settings  Status  Config  Usage  Stats
        Current\u{001B}[12Gsession
        ████████████████████████████████████████████████ 96% used
        Current\u{001B}[12Gweek\u{001B}[17G(all\u{001B}[22Gmodels)
        █████ 10% used
        Settings  Status  Config  Usage  Stats
        Current session
        ████████████████████████████████████████████████ 96% used
        Current week ( ll models)
        █████ 10% used
        """

        let snapshot = try #require(ProviderCapacityParser.claudeUsagePanel(output))

        #expect(snapshot.window(.session)?.usedPercentage == 96)
        #expect(snapshot.window(.weekly)?.usedPercentage == 10)
    }

    @Test("CLI refresh retains still-valid reset metadata from the status line")
    func retainsResetMetadata() throws {
        let oldObservedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newObservedAt = oldObservedAt.addingTimeInterval(900)
        let sessionReset = oldObservedAt.addingTimeInterval(4_000)
        let weeklyReset = oldObservedAt.addingTimeInterval(80_000)
        let previous = ProviderCapacitySnapshot(
            provider: .claude,
            windows: [
                CapacityWindowSnapshot(
                    provider: .claude,
                    kind: .session,
                    usedPercentage: 20,
                    resetsAt: sessionReset,
                    observedAt: oldObservedAt,
                    source: .claudeStatusLine
                ),
                CapacityWindowSnapshot(
                    provider: .claude,
                    kind: .weekly,
                    usedPercentage: 40,
                    resetsAt: weeklyReset,
                    observedAt: oldObservedAt,
                    source: .claudeStatusLine
                ),
            ],
            observedAt: oldObservedAt
        )
        let probed = try #require(ProviderCapacityParser.claudeUsagePanel(
            "Settings: Usage\nCurrent session 50% left\nResets in 1 hr\nCurrent week (all models) 25% left",
            observedAt: newObservedAt
        ))

        let merged = probed.preservingValidResetTimes(from: previous)

        #expect(merged.window(.session)?.resetsAt == sessionReset)
        #expect(merged.window(.weekly)?.resetsAt == weeklyReset)
        #expect(merged.window(.session)?.usedPercentage == 50)
        #expect(merged.window(.weekly)?.usedPercentage == 75)

        let partial = try #require(ProviderCapacityParser.claudeUsagePanel(
            "Settings: Usage\nCurrent session 45% left",
            observedAt: newObservedAt
        ))
        let partialMerged = partial.preservingValidResetTimes(from: previous)
        #expect(partialMerged.window(.weekly)?.usedPercentage == 40)
        #expect(partialMerged.window(.weekly)?.observedAt == oldObservedAt)
    }

    @Test("Claude CLI fallback runs only for stale disclosure data and observes cooldown")
    func claudeUsageFallbackPolicy() {
        let now = Date(timeIntervalSince1970: 20_000)
        let freshComplete = ProviderCapacitySnapshot(
            provider: .claude,
            windows: CapacityWindowKind.allCases.map { kind in
                CapacityWindowSnapshot(
                    provider: .claude,
                    kind: kind,
                    usedPercentage: 20,
                    resetsAt: nil,
                    observedAt: now.addingTimeInterval(-60),
                    source: .claudeStatusLine
                )
            },
            observedAt: now.addingTimeInterval(-60)
        )
        let freshIncomplete = ProviderCapacitySnapshot(
            provider: .claude,
            windows: [],
            observedAt: now.addingTimeInterval(-60)
        )
        let stale = ProviderCapacitySnapshot(
            provider: .claude,
            windows: [],
            observedAt: now.addingTimeInterval(-(CapacityPolicy.freshnessInterval + 1))
        )

        #expect(CapacityPolicy.shouldProbeClaudeUsage(snapshot: nil, lastAttemptAt: nil, now: now))
        #expect(!CapacityPolicy.shouldProbeClaudeUsage(
            snapshot: freshComplete,
            lastAttemptAt: nil,
            now: now
        ))
        #expect(CapacityPolicy.shouldProbeClaudeUsage(
            snapshot: freshIncomplete,
            lastAttemptAt: nil,
            now: now
        ))
        #expect(CapacityPolicy.shouldProbeClaudeUsage(snapshot: stale, lastAttemptAt: nil, now: now))
        #expect(!CapacityPolicy.shouldProbeClaudeUsage(
            snapshot: stale,
            lastAttemptAt: now.addingTimeInterval(-30),
            now: now
        ))
    }

    @Test("Stale and reset policies preserve honest state")
    func staleAndResetPolicy() {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let window = CapacityWindowSnapshot(
            provider: .claude,
            kind: .session,
            usedPercentage: 85,
            resetsAt: Date(timeIntervalSince1970: 2_000),
            observedAt: observedAt,
            source: .claudeStatusLine
        )

        #expect(!CapacityPolicy.isApproximate(
            window,
            refreshFailed: false,
            now: observedAt.addingTimeInterval(CapacityPolicy.freshnessInterval - 1)
        ))
        #expect(CapacityPolicy.isApproximate(
            window,
            refreshFailed: false,
            now: observedAt.addingTimeInterval(CapacityPolicy.freshnessInterval + 1)
        ))
        #expect(CapacityPolicy.isApproximate(window, refreshFailed: true, now: observedAt))
        #expect(window.isExpired(at: Date(timeIntervalSince1970: 2_000)))
    }
}

// MARK: - Per-model limits and reported rows

/// Shaped like Claude Code 2.1.280's `/usage` panel on a plan with a weekly
/// limit, a per-model weekly limit and no 5-hour window. The all-models block
/// is drawn with cursor moves between words, so its text arrives glued
/// together; the per-model block is redrawn later with ordinary spaces.
private let perModelPanel = """
\u{1B}[2JSettings: Usage
Currentweek(allmodels)
███████████████████████████████▌63%used
ResetsNov24at1:30pm(Asia/Calcutta)
What'scontributingtoyourlimitsusage?
Refreshing…
Current week (Fable)
███████████████████████████████████████████████    94% used
Resets Nov 24 at 1:30pm (Asia/Calcutta)
What's contributing to your limits usage?
"""

@Suite("Per-model usage limits")
struct PerModelCapacityTests {
    private let observedAt = ISO8601DateFormatter().date(from: "2026-11-22T16:19:30Z")!
    private let reset = ISO8601DateFormatter().date(from: "2026-11-24T08:00:00Z")!

    @Test("A per-model weekly limit is read beside the all-models one, glued text included")
    func parsesPerModelLimit() throws {
        let snapshot = try #require(ProviderCapacityParser.claudeUsagePanel(perModelPanel, observedAt: observedAt))
        let weekly = try #require(snapshot.window(.weekly))
        #expect(weekly.usedPercentage == 63)
        #expect(weekly.scope == nil)
        #expect(weekly.resetsAt == reset, "the glued reset line still parses")
        let fable = try #require(snapshot.window(.weekly, scope: "Fable"))
        #expect(fable.usedPercentage == 94)
        #expect(fable.remainingPercentage == 6)
        #expect(fable.resetsAt == reset)
        #expect(fable.source == .claudeCLIUsage)
        #expect(snapshot.window(.session) == nil, "this plan reports no 5-hour window")
        #expect(snapshot.modelWindows.map(\.scope) == ["Fable"])
        #expect(weekly.id != fable.id)
    }

    @Test("Model names are found once each and keep the spelling with spaces")
    func modelScopes() {
        let panel = """
        Currentweek(allmodels)
        Currentweek(Sonnetonly)
        40% used
        Current week (Sonnet only)
        41% used
        Current week (Fable)
        10% used
        """[...]
        #expect(ProviderCapacityParser.claudeUsageModelScopes(in: panel) == ["Sonnet only", "Fable"])
        let snapshot = ProviderCapacityParser.claudeUsagePanel(String(panel))
        #expect(snapshot?.window(.weekly, scope: "Sonnetonly")?.usedPercentage == 41, "names match by letters alone")
        #expect(snapshot?.window(.weekly) == nil, "the all-models block carried no percentage")
    }

    @Test("The panel shows exactly the limits Claude Code reported")
    func reportedRows() throws {
        // Before any reading, the usual two rows, both unavailable.
        #expect(CapacityRows.rows(for: nil).map(\.label) == ["7D", "5H"])

        // A plan without a 5-hour window gets no 5-hour row, and a row per model.
        let snapshot = try #require(ProviderCapacityParser.claudeUsagePanel(perModelPanel, observedAt: observedAt))
        let rows = CapacityRows.rows(for: snapshot)
        #expect(rows.map(\.label) == ["7D", "FABLE"])
        #expect(rows.map(\.name) == ["weekly", "Fable weekly"])
        #expect(rows[1].scope == "Fable")

        // A plan with both keeps both, all-models weekly first.
        let both = ProviderCapacitySnapshot(provider: .claude, windows: [
            CapacityWindowSnapshot(provider: .claude, kind: .session, usedPercentage: 20, resetsAt: nil, observedAt: observedAt, source: .claudeStatusLine),
            CapacityWindowSnapshot(provider: .claude, kind: .weekly, usedPercentage: 30, resetsAt: nil, observedAt: observedAt, source: .claudeStatusLine),
        ], observedAt: observedAt)
        #expect(CapacityRows.rows(for: both).map(\.label) == ["7D", "5H"])
    }

    @Test("Model labels fit the notch's pixel type")
    func modelLabels() {
        #expect(CapacityRows.label(forModel: "Fable") == "FABLE")
        #expect(CapacityRows.label(forModel: "Sonnet only") == "SONNET O")
        #expect(CapacityRows.label(forModel: "Opus 4.5") == "OPUS 4.5")
        #expect(CapacityRows.label(forModel: "✻ Ünïcode ✻") == "NCODE")
        #expect(CapacityRows.label(forModel: "✻✻") == "MODEL")
    }

    @Test("A later reading keeps a per-model reset time, and retains a briefly missing model limit")
    func mergesPerModelLimits() {
        let earlier = ProviderCapacitySnapshot(provider: .claude, windows: [
            CapacityWindowSnapshot(provider: .claude, kind: .weekly, usedPercentage: 90, resetsAt: reset, observedAt: observedAt, source: .claudeCLIUsage, scope: "Fable"),
            CapacityWindowSnapshot(provider: .claude, kind: .weekly, usedPercentage: 60, resetsAt: reset, observedAt: observedAt, source: .claudeCLIUsage),
        ], observedAt: observedAt)
        let later = observedAt.addingTimeInterval(600)

        // The reset line did not parse this time; the earlier one still holds.
        let noReset = ProviderCapacitySnapshot(provider: .claude, windows: [
            CapacityWindowSnapshot(provider: .claude, kind: .weekly, usedPercentage: 95, resetsAt: nil, observedAt: later, source: .claudeCLIUsage, scope: "Fable"),
            CapacityWindowSnapshot(provider: .claude, kind: .weekly, usedPercentage: 64, resetsAt: nil, observedAt: later, source: .claudeCLIUsage),
        ], observedAt: later).preservingValidResetTimes(from: earlier)
        #expect(noReset.window(.weekly, scope: "Fable")?.resetsAt == reset)
        #expect(noReset.window(.weekly, scope: "Fable")?.usedPercentage == 95)
        #expect(noReset.window(.weekly)?.resetsAt == reset)

        // A reading that omits the model limit keeps the earlier one until it resets.
        let omitted = ProviderCapacitySnapshot(provider: .claude, windows: [
            CapacityWindowSnapshot(provider: .claude, kind: .weekly, usedPercentage: 64, resetsAt: reset, observedAt: later, source: .claudeCLIUsage),
        ], observedAt: later)
        #expect(omitted.preservingValidResetTimes(from: earlier).window(.weekly, scope: "Fable")?.usedPercentage == 90)
        let afterReset = ProviderCapacitySnapshot(provider: .claude, windows: omitted.windows, observedAt: reset.addingTimeInterval(60))
        #expect(afterReset.preservingValidResetTimes(from: earlier).window(.weekly, scope: "Fable") == nil)
    }

    @Test("A cache saved before per-model limits still loads")
    func decodesOlderCache() throws {
        let saved = #"{"observedAt":"2026-11-22T16:19:30Z","provider":"claude","windows":[{"usedPercentage":63,"resetsAt":"2026-11-24T08:00:00Z","observedAt":"2026-11-22T16:19:30Z","source":"claudeCLIUsage","provider":"claude","kind":"weekly"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ProviderCapacitySnapshot.self, from: Data(saved.utf8))
        #expect(snapshot.window(.weekly)?.usedPercentage == 63)
        #expect(snapshot.window(.weekly)?.scope == nil)
        #expect(snapshot.modelWindows.isEmpty)
        #expect(CapacityRows.rows(for: snapshot).map(\.label) == ["7D"])
    }

    @Test("A snapshot with only a per-model limit has no all-models window")
    func scopedWindowsStaySeparate() {
        let onlyModel = ProviderCapacitySnapshot(provider: .claude, windows: [
            CapacityWindowSnapshot(provider: .claude, kind: .weekly, usedPercentage: 50, resetsAt: nil, observedAt: observedAt, source: .claudeCLIUsage, scope: "Fable"),
        ], observedAt: observedAt)
        #expect(onlyModel.window(.weekly) == nil)
        #expect(CapacityRows.rows(for: onlyModel).map(\.label) == ["FABLE"])
    }
}
