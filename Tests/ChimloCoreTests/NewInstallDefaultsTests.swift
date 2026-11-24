import Foundation
import Testing
@testable import ChimloCore

private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "overhead.defaults.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

/// 1.3.0 changed what a new installation starts with (the Obsidian theme).
/// A default that changes must reach new installations only: nobody who was
/// already using the app may see a setting move.
@Suite("New-installation defaults and upgrades")
struct NewInstallDefaultsTests {
    @Test("A new installation starts on Obsidian, with the RGB glow on")
    func newInstallation() throws {
        let fresh = OverheadSettings()
        #expect(fresh.theme == .obsidian)
        #expect(fresh.completionGlowEnabled)
        #expect(fresh.completionGlowTheme == .spectrum)
        #expect(fresh.completionGlow == CompletionGlow(theme: .spectrum, brightness: 0.8))

        try withIsolatedDefaults { defaults in
            let loaded = SettingsStore(defaults: defaults).load()
            #expect(loaded == fresh)
            #expect(loaded.theme == .obsidian)
        }
    }

    @Test("A new installation keeps Obsidian after setup and its first launches leave their marks")
    func newInstallationStaysNew() throws {
        try withIsolatedDefaults { defaults in
            // First launch: settings are read before the app writes anything.
            #expect(SettingsStore(defaults: defaults).load().theme == .obsidian)
            // Then the app starts, setup is finished, sessions come and go.
            for key in SettingsStore.existingInstallationKeys {
                defaults.set(key.hasSuffix("lastLaunchedVersion") ? "1.3.0" : "x", forKey: key)
            }
            // Every later launch reads what the first one saved.
            for _ in 0..<3 {
                let later = SettingsStore(defaults: defaults).load()
                #expect(later.theme == .obsidian)
                #expect(later == OverheadSettings())
            }
        }
    }

    @Test(
        "A copy that ran before but never saved a setting keeps Midnight",
        arguments: SettingsStore.existingInstallationKeys
    )
    func existingInstallationWithoutSavedSettings(marker: String) throws {
        try withIsolatedDefaults { defaults in
            // What such a copy left behind: one of the marks, and no settings.
            if marker == SettingsStore.legacySoundsEnabledKey {
                defaults.set(true, forKey: marker)
            } else {
                defaults.set("1.2.0", forKey: marker)
            }
            let loaded = SettingsStore(defaults: defaults).load()
            #expect(loaded.theme == .midnight, "\(marker)")
            // Nothing else differs from what it had: those defaults did not change.
            var expected = OverheadSettings()
            expected.theme = .midnight
            #expect(loaded == expected)
            #expect(loaded.completionGlow == CompletionGlow(theme: .spectrum, brightness: 0.8))
            // And it is settled: the next launch does not ask again.
            #expect(SettingsStore(defaults: defaults).load() == loaded)
        }
    }

    @Test("Every theme an owner chose survives the upgrade, Midnight and Obsidian included", arguments: ThemeID.allCases)
    func chosenThemeSurvives(theme: ThemeID) throws {
        try withIsolatedDefaults { defaults in
            // Saved by 1.2.0: a blob with every key, the theme among them.
            var old = OverheadSettings()
            old.theme = theme
            old.accent = .teal
            old.layout = .expanded
            old.setCompletionGlowEnabled(false)
            old.completionGlowTheme = .aurora
            old.glowIntensity = 0.4
            old.notifications.soundsEnabled = false
            old.notifications.soundChoice = .glass
            old.notifications.soundVolume = 0.3
            defaults.set(try JSONEncoder().encode(old), forKey: SettingsStore.storageKey)
            defaults.set("1.2.0", forKey: "overhead.update.lastLaunchedVersion")
            defaults.set(true, forKey: "overhead.onboarding.completed")
            let before = defaults.data(forKey: SettingsStore.storageKey)

            let loaded = SettingsStore(defaults: defaults).load()
            #expect(loaded == old)
            #expect(loaded.theme == theme)
            #expect(loaded.completionGlow == nil)
            #expect(loaded.completionGlowTheme == .aurora)
            #expect(loaded.glowIntensity == 0.4)
            #expect(loaded.notifications == old.notifications)
            // Reading it rewrites nothing.
            #expect(defaults.data(forKey: SettingsStore.storageKey) == before)
        }
    }

    @Test("Settings saved before the glow had a switch or a theme keep the glow they had")
    func olderSavedSettings() throws {
        try withIsolatedDefaults { defaults in
            // As 1.1.1 saved them: no glow switch, no glow theme.
            let json = #"{ "theme": "midnight", "glowIntensity": 0.6, "layout": "focus", "notifications": { "soundsEnabled": false } }"#
            defaults.set(Data(json.utf8), forKey: SettingsStore.storageKey)
            defaults.set("1.1.1", forKey: "overhead.update.lastLaunchedVersion")
            let loaded = SettingsStore(defaults: defaults).load()
            #expect(loaded.theme == .midnight)
            #expect(loaded.layout == .focus)
            #expect(loaded.completionGlow == CompletionGlow(theme: .spectrum, brightness: 0.6))
            #expect(!loaded.notifications.soundsEnabled)

            // And a glow turned off with the old slider stays off.
            let off = #"{ "theme": "graphite", "glowIntensity": 0 }"#
            defaults.set(Data(off.utf8), forKey: SettingsStore.storageKey)
            let quiet = SettingsStore(defaults: defaults).load()
            #expect(quiet.theme == .graphite)
            #expect(quiet.completionGlow == nil)
        }
    }

    @Test("The glow's defaults leave sound alone, and sound's leave the glow alone")
    func glowAndSoundDefaultsAreSeparate() throws {
        try withIsolatedDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let fresh = store.load()
            #expect(fresh.notifications == NotificationPreferences())
            let muted = store.update { $0.notifications.soundsEnabled = false }
            #expect(muted.completionGlow == fresh.completionGlow)
            let dark = store.update { $0.setCompletionGlowEnabled(false) }
            #expect(dark.notifications == muted.notifications)
        }
    }

    @Test("Reset gives the new defaults; an unreadable file gives them too and is kept aside")
    func resetAndCorruption() throws {
        try withIsolatedDefaults { defaults in
            defaults.set("oops", forKey: SettingsStore.storageKey)
            defaults.set("1.2.0", forKey: "overhead.update.lastLaunchedVersion")
            let loaded = SettingsStore(defaults: defaults).load()
            #expect(loaded == OverheadSettings())
            #expect(defaults.string(forKey: SettingsStore.corruptBackupKey) == "oops")
        }
    }

    @Test("Obsidian is a complete dark theme")
    func obsidianIsUsable() {
        #expect(ThemeLibrary.windowAppearanceIsDark(for: .obsidian) == true)
        let palette = ThemeLibrary.palette(for: .obsidian, systemIsDark: true)
        #expect(palette.isDark)
        #expect(RGBA.contrastRatio(palette.textPrimary, palette.background) >= 4.5)
        #expect(RGBA.contrastRatio(palette.textSecondary, palette.background) >= 4.5)
    }
}

/// The app half of the same rule, read from its source: settings must be
/// read before the app writes the marks that tell an old copy from a new one.
@Suite("New-installation defaults: app wiring")
struct NewInstallDefaultsWiringTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    private static func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    @Test("Settings are read before the app starts and marks itself as launched")
    func settingsAreReadFirst() throws {
        let app = try Self.source("ChimloApp.swift")
        let services = try #require(app.range(of: "let companion = CompanionWindowCoordinator(services: services)"))
        let start = try #require(app.range(of: "        model.start()\n        services.start()"))
        #expect(services.lowerBound < start.lowerBound)

        let model = try Self.source("ApplicationModel.swift")
        // The launch mark is written when the model starts, and nowhere earlier.
        #expect(model.components(separatedBy: "announceUpdateIfJustInstalled()").count - 1 == 2)
        let begin = try #require(model.range(of: "    func start() {\n"))
        let end = try #require(model[begin.upperBound...].range(of: "\n    }\n"))
        #expect(model[begin.upperBound..<end.lowerBound].contains("announceUpdateIfJustInstalled()"))
        let settingsModel = try Self.source("SettingsModel.swift")
        #expect(settingsModel.contains("settings = store.load()"))
    }

    @Test("The marks Core looks for are the ones the app writes")
    func marksMatch() throws {
        let sources = try ["ApplicationModel.swift", "FolderAccessModel.swift"].map(Self.source).joined()
        for key in ["overhead.update.lastLaunchedVersion", "overhead.onboarding.completed"] {
            #expect(SettingsStore.existingInstallationKeys.contains(key))
            #expect(sources.contains("\"\(key)\""), "\(key) is no longer written by the app")
        }
    }
}
