import Foundation
import Testing
@testable import ChimloCore

/// A fixed Gregorian calendar in UTC with a Saturday-Sunday weekend, so
/// time-of-day and weekday tests do not depend on the machine running them.
private enum Clock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// November 2026: the 18th is a Wednesday, the 20th a Friday, the 21st a
    /// Saturday, the 22nd a Sunday and the 23rd a Monday.
    static func date(day: Int, hour: Int, minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
    }
}

/// Runs `body` against a throwaway defaults suite and deletes it afterwards,
/// so tests never read or write the user's real preferences.
private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "overhead.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

@Suite("Daily windows")
struct DailyWindowTests {
    @Test("A same-day window includes its start and excludes its end")
    func sameDay() throws {
        let window = DailyWindow(startMinutes: 9 * 60, endMinutes: 17 * 60)
        #expect(window.contains(try Clock.date(day: 18, hour: 9), calendar: Clock.calendar))
        #expect(window.contains(try Clock.date(day: 18, hour: 16, minute: 59), calendar: Clock.calendar))
        #expect(!window.contains(try Clock.date(day: 18, hour: 17), calendar: Clock.calendar))
        #expect(!window.contains(try Clock.date(day: 18, hour: 8, minute: 59), calendar: Clock.calendar))
    }

    @Test("An overnight window crosses midnight")
    func overnight() throws {
        let window = DailyWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)
        #expect(window.contains(try Clock.date(day: 18, hour: 23), calendar: Clock.calendar))
        #expect(window.contains(try Clock.date(day: 19, hour: 0), calendar: Clock.calendar))
        #expect(window.contains(try Clock.date(day: 19, hour: 6, minute: 59), calendar: Clock.calendar))
        #expect(!window.contains(try Clock.date(day: 19, hour: 7), calendar: Clock.calendar))
        #expect(!window.contains(try Clock.date(day: 18, hour: 12), calendar: Clock.calendar))
        #expect(!window.contains(try Clock.date(day: 18, hour: 21, minute: 59), calendar: Clock.calendar))
    }

    @Test("Weekdays-only windows belong to the day they start")
    func weekdaysOnly() throws {
        #expect(Clock.calendar.component(.weekday, from: try Clock.date(day: 20, hour: 12)) == 6)

        let daytime = DailyWindow(startMinutes: 9 * 60, endMinutes: 17 * 60, weekdaysOnly: true)
        #expect(daytime.contains(try Clock.date(day: 20, hour: 10), calendar: Clock.calendar))
        #expect(!daytime.contains(try Clock.date(day: 21, hour: 10), calendar: Clock.calendar))
        #expect(!daytime.contains(try Clock.date(day: 22, hour: 10), calendar: Clock.calendar))

        let overnight = DailyWindow(startMinutes: 22 * 60, endMinutes: 7 * 60, weekdaysOnly: true)
        // Friday night's window runs into Saturday morning.
        #expect(overnight.contains(try Clock.date(day: 20, hour: 23), calendar: Clock.calendar))
        #expect(overnight.contains(try Clock.date(day: 21, hour: 3), calendar: Clock.calendar))
        // Saturday and Sunday nights have no window, so Monday early is free.
        #expect(!overnight.contains(try Clock.date(day: 21, hour: 23), calendar: Clock.calendar))
        #expect(!overnight.contains(try Clock.date(day: 23, hour: 3), calendar: Clock.calendar))
        // Sunday night is not a weekday, but Monday night is.
        #expect(!overnight.contains(try Clock.date(day: 22, hour: 23), calendar: Clock.calendar))
        #expect(overnight.contains(try Clock.date(day: 23, hour: 23), calendar: Clock.calendar))
    }

    @Test("Equal start and end is empty, and stray minutes wrap")
    func edges() throws {
        let empty = DailyWindow(startMinutes: 600, endMinutes: 600)
        #expect(!empty.contains(try Clock.date(day: 18, hour: 10), calendar: Clock.calendar))
        #expect(DailyWindow(startMinutes: 1500, endMinutes: -60).normalized() == DailyWindow(startMinutes: 60, endMinutes: 1380))
        let wrapped = DailyWindow(startMinutes: 1440 + 9 * 60, endMinutes: 17 * 60)
        #expect(wrapped.contains(try Clock.date(day: 18, hour: 12), calendar: Clock.calendar))
    }
}

@Suite("Overhead settings")
struct OverheadSettingsTests {
    @Test("Defaults match the product decisions")
    func defaults() {
        let settings = OverheadSettings()
        #expect(settings.version == OverheadSettings.currentVersion)
        #expect(settings.theme == .midnight)
        #expect(settings.accent == .claude)
        #expect(settings.appearance == .system)
        #expect(settings.animationIntensity == .full)
        #expect(settings.glowIntensity == 0.8)
        #expect(settings.layout == .classic)
        #expect(settings.density == .comfortable)
        #expect(settings.sessionSort == .attentionFirst)
        #expect(!settings.groupByProject)
        #expect(settings.historyRetentionDays == 90)
        #expect(settings.storeConversationPreviews)
        #expect(settings.contextAttentionThreshold == 0.7)
        #expect(settings.contextCriticalThreshold == 0.9)
        #expect(settings.usageWarningThreshold == 0.8)
        #expect(settings.showResetCountdowns && settings.showCacheMetrics)
        #expect(!settings.github.enabled)
        #expect(settings.github.refreshSeconds == 30)
        #expect(!settings.focus.isOn && !settings.focus.scheduleEnabled)
        #expect(settings.shortcuts == ShortcutDefaults.bindings)
        #expect(settings.shortcutsEnabled)
        #expect(!settings.dailyRecapEnabled)
        #expect(settings.notifications.soundsEnabled)
        #expect(settings.notifications.perEvent.isEmpty)
        #expect(settings.normalized() == settings)
    }

    @Test("Event defaults: critical sound on, banners opt-in, quiet ambient, selective GitHub")
    func eventDefaults() {
        let prefs = NotificationPreferences()
        for kind in OverheadEventKind.allCases {
            let preference = prefs.preference(for: kind)
            #expect(!preference.systemBanner, "\(kind) banner must be opt-in")
            if kind.isGitHub {
                let wanted: Set<OverheadEventKind> = [
                    .githubCIFailed, .githubReviewRequested, .githubChangesRequested,
                    .githubWorkflowFailed, .githubMergeConflict,
                ]
                #expect(preference.enabled == wanted.contains(kind), "\(kind)")
                #expect(!preference.sound, "\(kind) starts silent")
                // Failures, requested changes and conflicts need the owner;
                // nothing else from GitHub is critical.
                let critical: Set<OverheadEventKind> = [
                    .githubWorkflowFailed, .githubCIFailed, .githubChangesRequested, .githubMergeConflict,
                ]
                #expect((kind.priority == .critical) == critical.contains(kind), "\(kind)")
                #expect(!kind.blocksClaude, "\(kind)")
                continue
            }
            #expect(preference.enabled, "\(kind)")
            switch kind.priority {
            case .critical: #expect(preference.sound, "\(kind)")
            case .informational: #expect(preference.sound == (kind == .sessionCompleted), "\(kind)")
            case .ambient: #expect(!preference.sound, "\(kind)")
            }
        }
        #expect(OverheadEventKind.permissionRequested.priority == .critical)
        #expect(OverheadEventKind.sessionStarted.priority == .ambient)
        #expect(NotificationPriority.ambient < .informational && NotificationPriority.informational < .critical)
        #expect(OverheadEventKind.allCases.filter(\.blocksClaude) == [.permissionRequested, .questionAsked])
    }

    @Test("Every field survives a JSON round trip")
    func roundTrip() throws {
        var settings = OverheadSettings()
        settings.launchAtLogin = true
        settings.preferredDisplay = .displayWithPointer
        settings.theme = .warmAmber
        settings.accent = .teal
        settings.appearance = .dark
        settings.animationIntensity = .reduced
        settings.glowIntensity = 0.3
        settings.layout = .agentView
        settings.density = .compact
        settings.sessionSort = .project
        settings.groupByProject = true
        settings.historyRetentionDays = nil
        settings.storeConversationPreviews = false
        settings.notifications.soundsEnabled = false
        settings.notifications.perEvent[.sessionCompleted] = EventPreference(enabled: true, sound: false, systemBanner: true)
        settings.notifications.quietHours = DailyWindow(startMinutes: 1320, endMinutes: 420, weekdaysOnly: true)
        settings.notifications.quietHoursEnabled = true
        settings.notifications.groupCompletions = false
        settings.showAgents = false
        settings.contextAttentionThreshold = 0.6
        settings.contextCriticalThreshold = 0.85
        settings.usageWarningThreshold = 0.75
        settings.showResetCountdowns = false
        settings.showCacheMetrics = false
        settings.github = GitHubPreferences(enabled: true, trackPullRequests: false, monitorActions: true, reviewNotifications: false, refreshSeconds: 900)
        settings.focus = FocusPreferences(isOn: true, suppressInformational: true, muteSounds: false, reduceAnimations: false, hideActivityLabels: false, schedule: DailyWindow(startMinutes: 540, endMinutes: 720), scheduleEnabled: true)
        settings.shortcuts[.openHistory] = nil
        settings.shortcuts[.togglePanel] = KeyCombo(keyCode: 31, modifiers: [.command, .shift])
        settings.shortcutsEnabled = false
        settings.dailyRecapEnabled = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.historyRetentionDays == nil)
        #expect(decoded.shortcuts[.openHistory] == nil)
    }

    @Test("A sparse file keeps its values and fills the rest with defaults")
    func sparseDecoding() throws {
        let json = #"""
        {
          "theme": "obsidian",
          "notifications": { "soundsEnabled": false, "perEvent": { "activity": { "enabled": false } } },
          "github": { "enabled": true },
          "shortcuts": { "togglePanel": { "keyCode": 17, "modifiers": 5 }, "openHistory": null }
        }
        """#
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: Data(json.utf8))
        let defaults = OverheadSettings()
        #expect(decoded.theme == .obsidian)
        #expect(!decoded.notifications.soundsEnabled)
        #expect(decoded.notifications.groupCompletions == defaults.notifications.groupCompletions)
        #expect(decoded.notifications.perEvent[.activity] == EventPreference(enabled: false, sound: false, systemBanner: false))
        #expect(decoded.github.enabled)
        #expect(decoded.github.refreshSeconds == 30)
        #expect(decoded.github.monitorActions)
        #expect(decoded.layout == defaults.layout)
        #expect(decoded.accent == defaults.accent)
        #expect(decoded.historyRetentionDays == 90)
        #expect(decoded.contextCriticalThreshold == 0.9)
        #expect(decoded.focus == defaults.focus)
        #expect(decoded.version == OverheadSettings.currentVersion)
        // Explicit bindings and unbindings are kept; actions the file omits get defaults.
        #expect(decoded.shortcuts[.togglePanel] == KeyCombo(keyCode: 17, modifiers: [.command, .control]))
        #expect(decoded.shortcuts[.openHistory] == nil)
        #expect(decoded.shortcuts[.showSessions] == ShortcutDefaults.bindings[.showSessions])

        let empty = try JSONDecoder().decode(OverheadSettings.self, from: Data("{}".utf8))
        #expect(empty == defaults)
    }

    @Test("Unknown keys and values from a newer version cost only themselves")
    func forwardCompatibility() throws {
        let json = #"""
        {
          "version": 7,
          "theme": "aurora",
          "accent": "violet",
          "layout": "hologram",
          "glowIntensity": "bright",
          "futureFeature": { "nested": [1, 2, 3] },
          "notifications": { "perEvent": { "teleported": { "enabled": true }, "sessionFailed": { "enabled": false, "sound": true } } },
          "shortcuts": { "summonDragon": { "keyCode": 1, "modifiers": 1 } },
          "showAgents": false
        }
        """#
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: Data(json.utf8))
        #expect(decoded.version == 7)
        #expect(decoded.theme == .midnight)
        #expect(decoded.accent == .violet)
        #expect(decoded.layout == .classic)
        #expect(decoded.glowIntensity == 0.8)
        #expect(!decoded.showAgents)
        #expect(decoded.notifications.perEvent == [.sessionFailed: EventPreference(enabled: false, sound: true, systemBanner: false)])
        #expect(decoded.shortcuts == ShortcutDefaults.bindings)
    }

    @Test("Normalizing clamps every bounded value")
    func normalization() {
        var settings = OverheadSettings()
        settings.contextAttentionThreshold = 0.95
        settings.contextCriticalThreshold = 0.9
        settings.usageWarningThreshold = 5
        settings.glowIntensity = -1
        settings.github.refreshSeconds = 0
        settings.historyRetentionDays = 0
        settings.notifications.quietHours = DailyWindow(startMinutes: -60, endMinutes: 1500)
        settings.focus.schedule = DailyWindow(startMinutes: 1440, endMinutes: 60)
        let normalized = settings.normalized()
        #expect(normalized.contextCriticalThreshold == 0.9)
        #expect(normalized.contextAttentionThreshold < normalized.contextCriticalThreshold)
        #expect(abs(normalized.contextAttentionThreshold - 0.85) < 0.0001)
        #expect(normalized.usageWarningThreshold == 0.99)
        #expect(normalized.glowIntensity == 0)
        #expect(normalized.github.refreshSeconds == 30)
        #expect(normalized.historyRetentionDays == 1)
        #expect(normalized.notifications.quietHours == DailyWindow(startMinutes: 1380, endMinutes: 60))
        #expect(normalized.focus.schedule == DailyWindow(startMinutes: 0, endMinutes: 60))

        settings.contextAttentionThreshold = 0.1
        settings.contextCriticalThreshold = 2
        settings.glowIntensity = .nan
        settings.github.refreshSeconds = 100_000
        settings.historyRetentionDays = nil
        let high = settings.normalized()
        #expect(high.contextAttentionThreshold == 0.3)
        #expect(high.contextCriticalThreshold == 0.99)
        #expect(high.glowIntensity == 0.8)
        #expect(high.github.refreshSeconds == 3600)
        #expect(high.historyRetentionDays == nil)

        settings.contextAttentionThreshold = 0.2
        settings.contextCriticalThreshold = 0.2
        let low = settings.normalized()
        #expect(low.contextAttentionThreshold >= 0.3)
        #expect(low.contextAttentionThreshold < low.contextCriticalThreshold)
    }

    @Test("Focus is active when on or inside its enabled schedule")
    func focusActivity() throws {
        let calendar = Clock.calendar
        let morning = try Clock.date(day: 18, hour: 10)
        var focus = FocusPreferences()
        #expect(!focus.isActive(at: morning, calendar: calendar))
        focus.schedule = DailyWindow(startMinutes: 9 * 60, endMinutes: 12 * 60)
        #expect(!focus.isActive(at: morning, calendar: calendar))
        focus.scheduleEnabled = true
        #expect(focus.isActive(at: morning, calendar: calendar))
        #expect(!focus.isActive(at: try Clock.date(day: 18, hour: 13), calendar: calendar))
        focus.isOn = true
        #expect(focus.isActive(at: try Clock.date(day: 18, hour: 13), calendar: calendar))
    }
}

@Suite("Settings store")
struct SettingsStoreTests {
    @Test("First run migrates the legacy sound switch once and keeps the legacy key")
    func legacyMigration() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: SettingsStore.legacySoundsEnabledKey)
            let store = SettingsStore(defaults: defaults)
            let loaded = store.load()
            #expect(!loaded.notifications.soundsEnabled)
            #expect(defaults.object(forKey: SettingsStore.legacySoundsEnabledKey) as? Bool == false)
            #expect(defaults.data(forKey: SettingsStore.storageKey) != nil)

            // Once migrated, the blob wins over later legacy writes.
            defaults.set(true, forKey: SettingsStore.legacySoundsEnabledKey)
            let reloaded = SettingsStore(defaults: defaults).load()
            #expect(!reloaded.notifications.soundsEnabled)
        }
    }

    @Test("First run without legacy keys returns defaults and writes nothing")
    func freshInstall() throws {
        try withIsolatedDefaults { defaults in
            let loaded = SettingsStore(defaults: defaults).load()
            #expect(loaded == OverheadSettings())
            #expect(defaults.object(forKey: SettingsStore.storageKey) == nil)
        }
    }

    @Test("A corrupt blob yields defaults and is preserved for recovery")
    func corruptBlob() throws {
        try withIsolatedDefaults { defaults in
            let garbage = Data("{ not json".utf8)
            defaults.set(garbage, forKey: SettingsStore.storageKey)
            defaults.set(false, forKey: SettingsStore.legacySoundsEnabledKey)
            let store = SettingsStore(defaults: defaults)
            let loaded = store.load()
            #expect(loaded == OverheadSettings())
            #expect(defaults.data(forKey: SettingsStore.corruptBackupKey) == garbage)

            // A blob of the wrong type is kept too.
            defaults.set("oops", forKey: SettingsStore.storageKey)
            let again = store.load()
            #expect(again == OverheadSettings())
            #expect(defaults.string(forKey: SettingsStore.corruptBackupKey) == "oops")
        }
    }

    @Test("Saved settings load back, normalized")
    func saveAndLoad() throws {
        try withIsolatedDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            var settings = OverheadSettings()
            settings.theme = .arctic
            settings.layout = .focus
            settings.historyRetentionDays = nil
            settings.glowIntensity = 4
            settings.shortcuts[.toggleFocusMode] = nil
            store.save(settings)

            let loaded = SettingsStore(defaults: defaults).load()
            #expect(loaded == settings.normalized())
            #expect(loaded.glowIntensity == 1)
            #expect(loaded.historyRetentionDays == nil)
            #expect(loaded.shortcuts[.toggleFocusMode] == nil)

            let updated = store.update { $0.accent = .coral }
            #expect(updated.accent == .coral)
            #expect(updated.theme == .arctic)
            #expect(store.load() == updated)
        }
    }

    @Test("Concurrent updates through the store do not lose writes")
    func concurrentUpdates() async throws {
        let suiteName = "overhead.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = store.update { $0.github.refreshSeconds += 1 }
                }
            }
        }
        #expect(store.load().github.refreshSeconds == 50)
    }
}

@Suite("Notification policy")
struct NotificationPolicyTests {
    private let noon: Date
    private let context: NotificationContext

    init() throws {
        noon = try Clock.date(day: 18, hour: 12)
        context = NotificationContext(now: noon, calendar: Clock.calendar)
    }

    private func decide(
        _ kind: OverheadEventKind,
        key: String = "event-1",
        settings: OverheadSettings = OverheadSettings(),
        context: NotificationContext? = nil,
        ledger: inout DeliveryLedger
    ) -> NotificationDecision {
        NotificationPolicy.decide(kind, key: key, settings: settings, context: context ?? self.context, ledger: &ledger)
    }

    private func decideOnce(
        _ kind: OverheadEventKind,
        settings: OverheadSettings = OverheadSettings(),
        context: NotificationContext? = nil
    ) -> NotificationDecision {
        var ledger = DeliveryLedger()
        return decide(kind, settings: settings, context: context, ledger: &ledger)
    }

    private func settings(disabling kinds: [OverheadEventKind], sound: Bool = true) -> OverheadSettings {
        var settings = OverheadSettings()
        for kind in kinds {
            settings.notifications.perEvent[kind] = EventPreference(enabled: false, sound: sound, systemBanner: true)
        }
        return settings
    }

    @Test("Permission requests and questions are never hidden")
    func blockingEventsAlwaysShow() throws {
        var hostile = settings(disabling: [.permissionRequested, .questionAsked], sound: false)
        hostile.focus.isOn = true
        hostile.focus.suppressInformational = true
        hostile.notifications.quietHours = DailyWindow(startMinutes: 0, endMinutes: 1439)
        hostile.notifications.quietHoursEnabled = true
        let quietContext = NotificationContext(now: noon, calendar: Clock.calendar, systemFocusActive: true)
        for kind in [OverheadEventKind.permissionRequested, .questionAsked] {
            let decision = decideOnce(kind, settings: hostile, context: quietContext)
            #expect(decision.showInNotch && decision.expandNotch, "\(kind)")
            #expect(!decision.playSound, "\(kind)")
            #expect(decision.postSystemBanner, "\(kind) banner follows its preference")
        }
        // Disabled but with sound on: the sound still follows the preference.
        let disabledWithSound = settings(disabling: [.permissionRequested], sound: true)
        let loud = decideOnce(.permissionRequested, settings: disabledWithSound)
        #expect(loud.showInNotch && loud.expandNotch && loud.playSound)
    }

    @Test("Other disabled kinds are suppressed")
    func disabledKinds() {
        let disabled = settings(disabling: [.sessionFailed, .sessionCompleted, .activity])
        #expect(decideOnce(.sessionFailed, settings: disabled) == .suppressed)
        #expect(decideOnce(.sessionCompleted, settings: disabled) == .suppressed)
        #expect(decideOnce(.activity, settings: disabled) == .suppressed)
        #expect(decideOnce(.integrationError, settings: disabled).showInNotch)
    }

    @Test("Duplicates are suppressed for 10 minutes, critical ones for 30 seconds")
    func deduplication() {
        var ledger = DeliveryLedger()
        let first = decide(.sessionCompleted, ledger: &ledger)
        #expect(first.showInNotch)
        let soon = decide(.sessionCompleted, context: NotificationContext(now: noon.addingTimeInterval(599), calendar: Clock.calendar), ledger: &ledger)
        #expect(soon == .suppressed)
        let later = decide(.sessionCompleted, context: NotificationContext(now: noon.addingTimeInterval(600), calendar: Clock.calendar), ledger: &ledger)
        #expect(later.showInNotch)

        var critical = DeliveryLedger()
        let asked = decide(.permissionRequested, ledger: &critical)
        #expect(asked.expandNotch)
        let echo = decide(.permissionRequested, context: NotificationContext(now: noon.addingTimeInterval(29), calendar: Clock.calendar), ledger: &critical)
        #expect(echo == .suppressed)
        let reasked = decide(.permissionRequested, context: NotificationContext(now: noon.addingTimeInterval(30), calendar: Clock.calendar), ledger: &critical)
        #expect(reasked.showInNotch && reasked.expandNotch)
    }

    @Test("Dedupe keys are per kind, empty keys never dedupe, and echoes do not extend the window")
    func deduplicationDetails() {
        var ledger = DeliveryLedger()
        let completed = decide(.sessionCompleted, key: "s1", ledger: &ledger)
        let failed = decide(.sessionFailed, key: "s1", ledger: &ledger)
        #expect(completed.showInNotch && failed.showInNotch)

        var anonymous = DeliveryLedger()
        let one = decide(.activity, key: "", ledger: &anonymous)
        let two = decide(.activity, key: "", ledger: &anonymous)
        #expect(one.showInNotch && two.showInNotch)
        #expect(anonymous.count == 0)

        var echoes = DeliveryLedger()
        _ = decide(.contextWarning, key: "ctx", ledger: &echoes)
        let echo = decide(.contextWarning, key: "ctx", context: NotificationContext(now: noon.addingTimeInterval(300), calendar: Clock.calendar), ledger: &echoes)
        #expect(echo == .suppressed)
        let afterFirstWindow = decide(.contextWarning, key: "ctx", context: NotificationContext(now: noon.addingTimeInterval(601), calendar: Clock.calendar), ledger: &echoes)
        #expect(afterFirstWindow.showInNotch)
    }

    @Test("Suppressed events are not recorded as delivered")
    func suppressedNotRecorded() {
        var ledger = DeliveryLedger()
        let disabled = settings(disabling: [.sessionCompleted])
        _ = decide(.sessionCompleted, key: "s1", settings: disabled, ledger: &ledger)
        #expect(ledger.count == 0)
        let enabled = decide(.sessionCompleted, key: "s1", ledger: &ledger)
        #expect(enabled.showInNotch)
    }

    @Test("The ledger stays bounded and evicts the oldest delivery")
    func ledgerBound() {
        var ledger = DeliveryLedger()
        for index in 0..<(DeliveryLedger.capacity + 25) {
            ledger.record("key-\(index)", at: noon.addingTimeInterval(TimeInterval(index)))
        }
        #expect(ledger.count == DeliveryLedger.capacity)
        #expect(ledger.lastDelivery(of: "key-0") == nil)
        #expect(ledger.lastDelivery(of: "key-24") == nil)
        #expect(ledger.lastDelivery(of: "key-25") != nil)
    }

    @Test("Focus silences informational events and optionally hides them")
    func focusMode() {
        var focused = OverheadSettings()
        focused.focus.isOn = true
        focused.notifications.perEvent[.sessionCompleted] = EventPreference(enabled: true, sound: true, systemBanner: true)

        let completed = decideOnce(.sessionCompleted, settings: focused)
        #expect(completed.showInNotch && !completed.expandNotch)
        #expect(!completed.playSound && !completed.postSystemBanner)

        let ambient = decideOnce(.activity, settings: focused)
        #expect(ambient.showInNotch && !ambient.playSound && !ambient.postSystemBanner)

        // Critical still shows and expands; muteSounds (on by default) silences it.
        let failure = decideOnce(.sessionFailed, settings: focused)
        #expect(failure.showInNotch && failure.expandNotch && !failure.playSound)

        focused.focus.muteSounds = false
        let audibleFailure = decideOnce(.sessionFailed, settings: focused)
        #expect(audibleFailure.playSound)

        focused.notifications.perEvent[.sessionFailed] = EventPreference(enabled: true, sound: true, systemBanner: true)
        #expect(decideOnce(.sessionFailed, settings: focused).postSystemBanner)

        focused.focus.suppressInformational = true
        #expect(decideOnce(.sessionCompleted, settings: focused) == .suppressed)
        #expect(decideOnce(.activity, settings: focused).showInNotch)
        #expect(decideOnce(.sessionFailed, settings: focused).expandNotch)
    }

    @Test("A Focus schedule counts as Focus")
    func scheduledFocus() throws {
        var scheduled = OverheadSettings()
        scheduled.focus.schedule = DailyWindow(startMinutes: 11 * 60, endMinutes: 13 * 60)
        scheduled.focus.scheduleEnabled = true
        #expect(!decideOnce(.sessionCompleted, settings: scheduled).playSound)
        let evening = NotificationContext(now: try Clock.date(day: 18, hour: 18), calendar: Clock.calendar)
        #expect(decideOnce(.sessionCompleted, settings: scheduled, context: evening).playSound)
    }

    @Test("Quiet hours mute sounds, including critical ones")
    func quietHours() throws {
        var quiet = OverheadSettings()
        quiet.focus.muteSounds = false
        quiet.notifications.quietHours = DailyWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)
        quiet.notifications.quietHoursEnabled = true
        let night = NotificationContext(now: try Clock.date(day: 18, hour: 23), calendar: Clock.calendar)

        let failure = decideOnce(.sessionFailed, settings: quiet, context: night)
        #expect(failure.showInNotch && failure.expandNotch && !failure.playSound)
        let completed = decideOnce(.sessionCompleted, settings: quiet, context: night)
        #expect(completed.showInNotch && !completed.playSound)

        // Outside the window, and with the window disabled, sounds return.
        #expect(decideOnce(.sessionFailed, settings: quiet).playSound)
        quiet.notifications.quietHoursEnabled = false
        #expect(decideOnce(.sessionFailed, settings: quiet, context: night).playSound)
    }

    @Test("macOS Focus is treated as quiet")
    func systemFocus() {
        let systemFocus = NotificationContext(now: noon, calendar: Clock.calendar, systemFocusActive: true)
        let completed = decideOnce(.sessionCompleted, context: systemFocus)
        #expect(completed.showInNotch && !completed.playSound)
        let failure = decideOnce(.sessionFailed, context: systemFocus)
        #expect(failure.expandNotch && !failure.playSound)

        var audible = OverheadSettings()
        audible.focus.muteSounds = false
        #expect(decideOnce(.sessionFailed, settings: audible, context: systemFocus).playSound)
    }

    @Test("Ambient events only ever show in the notch")
    func ambientEvents() {
        var loud = OverheadSettings()
        loud.notifications.perEvent[.activity] = EventPreference(enabled: true, sound: true, systemBanner: true)
        let decision = decideOnce(.activity, settings: loud)
        #expect(decision == NotificationDecision(showInNotch: true, expandNotch: false, playSound: false, postSystemBanner: false))
        #expect(decideOnce(.sessionStarted) == decision)
    }

    @Test("Informational events show without expanding; sound needs pref and global switch")
    func informationalEvents() {
        let completed = decideOnce(.sessionCompleted)
        #expect(completed.showInNotch && !completed.expandNotch && completed.playSound && !completed.postSystemBanner)
        #expect(!decideOnce(.agentCompleted).playSound)
        #expect(!decideOnce(.contextWarning).expandNotch)

        var muted = OverheadSettings()
        muted.notifications.soundsEnabled = false
        #expect(!decideOnce(.sessionCompleted, settings: muted).playSound)

        var banner = OverheadSettings()
        banner.notifications.perEvent[.usageWarning] = EventPreference(enabled: true, sound: false, systemBanner: true)
        #expect(decideOnce(.usageWarning, settings: banner).postSystemBanner)
    }

    @Test("Critical events expand; sound and banner follow prefs and the global switch")
    func criticalEvents() {
        let failure = decideOnce(.sessionFailed)
        #expect(failure.showInNotch && failure.expandNotch && failure.playSound && !failure.postSystemBanner)

        var muted = OverheadSettings()
        muted.notifications.soundsEnabled = false
        let silent = decideOnce(.permissionRequested, settings: muted)
        #expect(silent.expandNotch && !silent.playSound)

        var banner = OverheadSettings()
        banner.notifications.perEvent[.integrationError] = EventPreference(enabled: true, sound: false, systemBanner: true)
        let error = decideOnce(.integrationError, settings: banner)
        #expect(error.postSystemBanner && !error.playSound)
    }

    @Test("Completions share a group key when grouping is on")
    func grouping() {
        #expect(decideOnce(.sessionCompleted).groupKey == NotificationPolicy.completionsGroupKey)
        #expect(decideOnce(.agentCompleted).groupKey == "completions")
        #expect(decideOnce(.sessionFailed).groupKey == nil)
        var ungrouped = OverheadSettings()
        ungrouped.notifications.groupCompletions = false
        #expect(decideOnce(.sessionCompleted, settings: ungrouped).groupKey == nil)
    }

    @Test("GitHub events are suppressed until GitHub is enabled, then follow prefs")
    func gitHub() {
        let disconnected = OverheadSettings()
        for kind in OverheadEventKind.allCases where kind.isGitHub {
            #expect(decideOnce(kind, settings: disconnected) == .suppressed, "\(kind)")
        }
        var connected = OverheadSettings()
        connected.github.enabled = true
        let ciFailed = decideOnce(.githubCIFailed, settings: connected)
        #expect(ciFailed.showInNotch && !ciFailed.expandNotch && !ciFailed.playSound)
        #expect(decideOnce(.githubReviewRequested, settings: connected).showInNotch)
        #expect(decideOnce(.githubMerged, settings: connected) == .suppressed)

        connected.notifications.perEvent[.githubMerged] = EventPreference(enabled: true, sound: false, systemBanner: false)
        #expect(decideOnce(.githubMerged, settings: connected).showInNotch)

        connected.github.monitorActions = false
        #expect(decideOnce(.githubCIFailed, settings: connected) == .suppressed)
        connected.github.reviewNotifications = false
        #expect(decideOnce(.githubReviewRequested, settings: connected) == .suppressed)
        #expect(decideOnce(.githubMerged, settings: connected).showInNotch)
        connected.github.trackPullRequests = false
        #expect(decideOnce(.githubMerged, settings: connected) == .suppressed)
    }
}
