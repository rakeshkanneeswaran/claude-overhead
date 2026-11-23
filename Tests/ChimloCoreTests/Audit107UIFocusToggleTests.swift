import ChimloCore
import Foundation
import Testing

/// The notch's Focus button says "Turn off Focus mode" whenever Focus is
/// active, so it must turn it off even when a schedule is what keeps it on.
@Suite("Audit 1.0.7 UI: the Focus button")
struct Audit107UIFocusToggleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// A Wednesday in November 2026.
    private func date(day: Int = 18, hour: Int, minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
    }

    private var scheduled: FocusPreferences {
        FocusPreferences(schedule: DailyWindow(startMinutes: 9 * 60, endMinutes: 12 * 60), scheduleEnabled: true)
    }

    @Test("Off during a scheduled window turns Focus off for the rest of that window")
    func offDuringSchedule() throws {
        var focus = scheduled
        let ten = try date(hour: 10)
        #expect(focus.isActive(at: ten, calendar: calendar))
        focus.toggle(at: ten, calendar: calendar)
        #expect(!focus.isOn)
        #expect(!focus.isActive(at: ten, calendar: calendar))
        #expect(!focus.isActive(at: try date(hour: 11, minute: 59), calendar: calendar))
        #expect(focus.schedulePausedUntil == (try date(hour: 12)))
        // The schedule itself is untouched and comes back with the next window.
        #expect(focus.scheduleEnabled)
        #expect(focus.isActive(at: try date(day: 19, hour: 10), calendar: calendar))
    }

    @Test("On again during the paused window turns Focus on by hand")
    func onWhilePaused() throws {
        var focus = scheduled
        let ten = try date(hour: 10)
        focus.toggle(at: ten, calendar: calendar)
        focus.toggle(at: try date(hour: 10, minute: 30), calendar: calendar)
        #expect(focus.isOn)
        #expect(focus.schedulePausedUntil == nil)
        #expect(focus.isActive(at: try date(hour: 10, minute: 30), calendar: calendar))
        // And off once more works again.
        focus.toggle(at: try date(hour: 10, minute: 45), calendar: calendar)
        #expect(!focus.isActive(at: try date(hour: 10, minute: 45), calendar: calendar))
    }

    @Test("Manual Focus, switched off inside a scheduled window, is off too")
    func manualAndScheduledTogether() throws {
        var focus = scheduled
        focus.isOn = true
        let ten = try date(hour: 10)
        focus.toggle(at: ten, calendar: calendar)
        #expect(!focus.isActive(at: ten, calendar: calendar))
    }

    @Test("Outside any schedule the button is the plain manual switch it always was")
    func manualOnly() throws {
        var focus = FocusPreferences()
        let noon = try date(hour: 14)
        focus.toggle(at: noon, calendar: calendar)
        #expect(focus.isOn && focus.isActive(at: noon, calendar: calendar))
        focus.toggle(at: noon, calendar: calendar)
        #expect(!focus.isOn && !focus.isActive(at: noon, calendar: calendar))
        #expect(focus.schedulePausedUntil == nil)

        // With a schedule that is not running now, likewise.
        var later = scheduled
        later.toggle(at: noon, calendar: calendar)
        #expect(later.isOn)
        later.toggle(at: noon, calendar: calendar)
        #expect(!later.isOn && later.schedulePausedUntil == nil)
    }

    @Test("An overnight window is paused until the morning it ends")
    func overnightWindow() throws {
        var focus = FocusPreferences(schedule: DailyWindow(startMinutes: 22 * 60, endMinutes: 7 * 60), scheduleEnabled: true)
        let lateEvening = try date(hour: 23)
        focus.toggle(at: lateEvening, calendar: calendar)
        #expect(focus.schedulePausedUntil == (try date(day: 19, hour: 7)))
        #expect(!focus.isActive(at: try date(day: 19, hour: 3), calendar: calendar))
        #expect(focus.isActive(at: try date(day: 19, hour: 23), calendar: calendar))
    }

    @Test("The window's end is only known from inside the window")
    func windowEnd() throws {
        let window = DailyWindow(startMinutes: 9 * 60, endMinutes: 12 * 60)
        #expect(window.end(ofWindowContaining: try date(hour: 9), calendar: calendar) == (try date(hour: 12)))
        #expect(window.end(ofWindowContaining: try date(hour: 13), calendar: calendar) == nil)
    }

    @Test("The pause survives saving, and older settings read without it")
    func persistence() throws {
        var settings = OverheadSettings()
        settings.focus = scheduled
        settings.focus.toggle(at: try date(hour: 10), calendar: calendar)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: data)
        #expect(decoded.focus == settings.focus)
        #expect(decoded.focus.schedulePausedUntil == (try date(hour: 12)))

        let old = Data(#"{"focus":{"isOn":false,"scheduleEnabled":true,"schedule":{"startMinutes":540,"endMinutes":720}}}"#.utf8)
        let fromOld = try JSONDecoder().decode(OverheadSettings.self, from: old)
        #expect(fromOld.focus.schedulePausedUntil == nil)
        #expect(fromOld.focus.isActive(at: try date(hour: 10), calendar: calendar))
    }
}
