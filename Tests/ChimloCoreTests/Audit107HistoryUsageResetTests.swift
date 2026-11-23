import Foundation
import Testing
@testable import ChimloCore

/// Reset times on Claude Code's `/usage` panel. On the hour the panel drops
/// the minutes ("Resets 3pm"); without a reset time a limit never expires and
/// the old percentage stays on screen after the real reset.
@Suite("Audit 1.0.7: usage reset times without minutes")
struct Audit107HistoryUsageResetTests {
    private let zone = "Asia/Calcutta"

    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)))
    }

    private func panel(session: String, weekly: String) -> String {
        """
        Settings  Status  Config  Usage  Stats
        Current session
        12% used
        \(session)
        Current week (all models)
        40% used
        \(weekly)
        """
    }

    @Test("Session and weekly resets parse with and without minutes")
    func bothSpellings() throws {
        let calendar = try calendar()
        let observedAt = try date(calendar, 2026, 7, 22, 12)

        let onTheHour = try #require(ProviderCapacityParser.claudeUsagePanel(
            panel(session: "Resets 3pm (\(zone))", weekly: "Resets Jul 27 at 7pm (\(zone))"),
            observedAt: observedAt
        ))
        #expect(onTheHour.window(.session)?.resetsAt == (try date(calendar, 2026, 7, 22, 15)))
        #expect(onTheHour.window(.weekly)?.resetsAt == (try date(calendar, 2026, 7, 27, 19)))

        let withMinutes = try #require(ProviderCapacityParser.claudeUsagePanel(
            panel(session: "Resets 3:05pm (\(zone))", weekly: "Resets Jul 27 at 7:29pm (\(zone))"),
            observedAt: observedAt
        ))
        #expect(withMinutes.window(.session)?.resetsAt == (try date(calendar, 2026, 7, 22, 15, 5)))
        #expect(withMinutes.window(.weekly)?.resetsAt == (try date(calendar, 2026, 7, 27, 19, 29)))
    }

    @Test("Midnight, noon, an hour already past today, and glued text all read on the hour")
    func hourOnlyEdges() throws {
        let calendar = try calendar()
        let observedAt = try date(calendar, 2026, 7, 22, 12, 30)

        let snapshot = try #require(ProviderCapacityParser.claudeUsagePanel(
            panel(session: "Resets 12am (\(zone))", weekly: "ResetsJul27at12pm(\(zone))"),
            observedAt: observedAt
        ))
        #expect(snapshot.window(.session)?.resetsAt == (try date(calendar, 2026, 7, 23, 0)), "12am is the coming midnight")
        #expect(snapshot.window(.weekly)?.resetsAt == (try date(calendar, 2026, 7, 27, 12)))

        let pastToday = try #require(ProviderCapacityParser.claudeUsagePanel(
            panel(session: "Resets 9am (\(zone))", weekly: "Resets Jul 27 at 7 PM (\(zone))"),
            observedAt: observedAt
        ))
        #expect(pastToday.window(.session)?.resetsAt == (try date(calendar, 2026, 7, 23, 9)), "9am has passed, so tomorrow's")
        #expect(pastToday.window(.weekly)?.resetsAt == (try date(calendar, 2026, 7, 27, 19)))
    }

    @Test("Without a time zone the Mac's own zone is used, as it is with minutes")
    func localZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let observedAt = try date(calendar, 2026, 7, 22, 12)

        let snapshot = try #require(ProviderCapacityParser.claudeUsagePanel(
            panel(session: "Resets 3pm", weekly: "Resets Jul 27 at 7pm"),
            observedAt: observedAt
        ))
        #expect(snapshot.window(.session)?.resetsAt == (try date(calendar, 2026, 7, 22, 15)))
        #expect(snapshot.window(.weekly)?.resetsAt == (try date(calendar, 2026, 7, 27, 19)))
    }

    @Test("Times that are not times still give no reset")
    func invalidTimesRejected() throws {
        let calendar = try calendar()
        let observedAt = try date(calendar, 2026, 7, 22, 12)

        let snapshot = try #require(ProviderCapacityParser.claudeUsagePanel(
            panel(session: "Resets 13pm (\(zone))", weekly: "Resets Jul 27 at 7:75pm (\(zone))"),
            observedAt: observedAt
        ))
        #expect(snapshot.window(.session)?.usedPercentage == 12)
        #expect(snapshot.window(.session)?.resetsAt == nil)
        #expect(snapshot.window(.weekly)?.resetsAt == nil)
    }

    @Test("A weekly reset read in the minute it passes ends then, not a year later")
    func weeklyJustPassed() throws {
        let calendar = try calendar()
        let reset = try date(calendar, 2026, 7, 27, 19, 29)
        let text = panel(session: "Resets 9pm (\(zone))", weekly: "Resets Jul 27 at 7:29pm (\(zone))")

        // The panel still shows 7:29pm twenty seconds after it.
        let during = try #require(ProviderCapacityParser.claudeUsagePanel(text, observedAt: reset.addingTimeInterval(20)))
        let weekly = try #require(during.window(.weekly)?.resetsAt)
        #expect(weekly == reset.addingTimeInterval(60))
        #expect(weekly.timeIntervalSince(reset) < 120, "not next year's July 27")

        // Exactly on the minute counts as passing too.
        let onTheDot = try #require(ProviderCapacityParser.claudeUsagePanel(text, observedAt: reset))
        #expect(onTheDot.window(.weekly)?.resetsAt == reset.addingTimeInterval(60))

        // A date well in the past is still read as next year's, as before.
        let longAfter = try #require(ProviderCapacityParser.claudeUsagePanel(text, observedAt: reset.addingTimeInterval(3 * 86_400)))
        #expect(longAfter.window(.weekly)?.resetsAt == (try date(calendar, 2027, 7, 27, 19, 29)))

        // And one still ahead is untouched.
        let before = try #require(ProviderCapacityParser.claudeUsagePanel(text, observedAt: reset.addingTimeInterval(-3_600)))
        #expect(before.window(.weekly)?.resetsAt == reset)
    }
}
