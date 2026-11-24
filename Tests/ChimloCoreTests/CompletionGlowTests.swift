import Foundation
import Testing
@testable import ChimloCore

private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "overhead.glow.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

private func decode(_ json: String) throws -> OverheadSettings {
    try JSONDecoder().decode(OverheadSettings.self, from: Data(json.utf8))
}

/// Whether a finished turn in `sessionID` plays its sound, decided the way
/// the app decides it: the notification policy, then that session's bell.
private func completionSounds(_ settings: OverheadSettings, bellOn: Bool, sessionID: String = "s1") -> Bool {
    var ledger = DeliveryLedger()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let policy = NotificationPolicy.decide(
        .sessionCompleted,
        key: "\(sessionID)|reply",
        settings: settings,
        context: NotificationContext(now: now),
        ledger: &ledger
    )
    var bells = SessionSoundPreferences()
    bells.setEnabled(bellOn, for: sessionID, at: now)
    var gate = SessionSoundGate()
    return gate.allows(
        .sessionCompleted, sessionID: sessionID, policyAllows: policy.playSound, preferences: bells, now: now
    )
}

/// The colour a frame puts at one point of the notch's box (0...1 each way),
/// over the black notch. Outlines are left out: they are a line at the edge.
private func color(of layers: [GlowLayer], x: Double, y: Double) -> [Double] {
    func blend(_ stops: [GlowStop], at place: Double) -> RGBA {
        guard let first = stops.first, let last = stops.last else { return RGBA(0x000000, alpha: 0) }
        if place <= first.location { return first.color }
        if place >= last.location { return last.color }
        for (lower, upper) in zip(stops, stops.dropFirst()) where place <= upper.location {
            let span = upper.location - lower.location
            return span > 0 ? lower.color.mixed(with: upper.color, by: (place - lower.location) / span) : upper.color
        }
        return last.color
    }
    var result = [0.0, 0.0, 0.0]
    for layer in layers {
        let place: Double
        switch layer.form {
        case let .linear(startX, startY, endX, endY):
            let dx = endX - startX, dy = endY - startY
            place = ((x - startX) * dx + (y - startY) * dy) / (dx * dx + dy * dy)
        case let .radial(centerX, centerY, radius):
            place = ((x - centerX) * (x - centerX) + (y - centerY) * (y - centerY)).squareRoot() / radius
        case .outline:
            continue
        }
        let color = blend(layer.stops, at: min(max(place, 0), 1))
        let cover = color.alpha * layer.opacity
        result = zip([color.red, color.green, color.blue], result).map { $0 * cover + $1 * (1 - cover) }
    }
    return result
}

/// The largest difference between two frames, anywhere on the notch.
private func difference(_ first: [GlowLayer], _ second: [GlowLayer]) -> Double {
    var worst = 0.0
    for column in 0...40 {
        for row in 0...4 {
            let x = Double(column) / 40, y = Double(row) / 4
            let pair = zip(color(of: first, x: x, y: y), color(of: second, x: x, y: y))
            worst = max(worst, pair.map { abs($0 - $1) }.max() ?? 0)
        }
    }
    return worst
}

// MARK: - The switch

@Suite("Completion glow: on, off and sound")
struct CompletionGlowSwitchTests {
    @Test("The glow starts on, as the RGB wave it has always been")
    func defaults() {
        let settings = OverheadSettings()
        #expect(settings.completionGlowEnabled)
        #expect(settings.completionGlowTheme == .spectrum)
        #expect(settings.completionGlow == CompletionGlow(theme: .spectrum, brightness: 0.8))
    }

    @Test(
        "Glow and sound are two choices: every combination gives exactly what was asked for",
        arguments: [(false, false), (false, true), (true, false), (true, true)]
    )
    func combinations(glowOn: Bool, soundOn: Bool) {
        var settings = OverheadSettings()
        settings.setCompletionGlowEnabled(glowOn)
        #expect((settings.completionGlow != nil) == glowOn)
        #expect(completionSounds(settings, bellOn: soundOn) == soundOn)
    }

    @Test("Turning the glow off or changing its theme changes nothing about sound")
    func glowLeavesSoundAlone() {
        var settings = OverheadSettings()
        let before = settings.notifications
        for theme in GlowTheme.allCases {
            settings.completionGlowTheme = theme
            settings.setCompletionGlowEnabled(false)
            #expect(completionSounds(settings, bellOn: true))
            #expect(!completionSounds(settings, bellOn: false))
            settings.setCompletionGlowEnabled(true)
            #expect(completionSounds(settings, bellOn: true))
        }
        #expect(settings.notifications == before)
    }

    @Test("No sound setting changes the glow")
    func soundLeavesGlowAlone() {
        var settings = OverheadSettings()
        settings.completionGlowTheme = .aurora
        let glow = settings.completionGlow
        settings.notifications.soundsEnabled = false
        #expect(settings.completionGlow == glow)
        settings.notifications.perEvent[.sessionCompleted] = EventPreference(enabled: true, sound: false, systemBanner: false)
        #expect(settings.completionGlow == glow)
        settings.notifications.soundVolume = 0.05
        settings.focus = FocusPreferences(isOn: true, muteSounds: true)
        #expect(settings.completionGlow == glow)
        #expect(!completionSounds(settings, bellOn: true))

        settings.setCompletionGlowEnabled(false)
        settings.notifications = NotificationPreferences()
        settings.focus = FocusPreferences()
        #expect(settings.completionGlow == nil)
    }

    @Test("With several sessions, each bell decides its own sound and the glow is one switch for all")
    func severalSessions() {
        var settings = OverheadSettings()
        settings.setCompletionGlowEnabled(false)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var bells = SessionSoundPreferences()
        bells.setEnabled(true, for: "loud", at: now)
        var gate = SessionSoundGate()
        let loud = gate.allows(.sessionCompleted, sessionID: "loud", policyAllows: true, preferences: bells, now: now)
        let quiet = gate.allows(.sessionCompleted, sessionID: "quiet", policyAllows: true, preferences: bells, now: now)
        #expect(loud && !quiet)
        #expect(settings.completionGlow == nil)
    }

    @Test("Turning the glow off keeps its theme and brightness for next time")
    func offKeepsTheChoice() {
        var settings = OverheadSettings()
        settings.completionGlowTheme = .cyberpunk
        settings.glowIntensity = 0.55
        settings.setCompletionGlowEnabled(false)
        #expect(settings.completionGlow == nil)
        #expect(settings.completionGlowTheme == .cyberpunk)
        #expect(settings.glowIntensity == 0.55)
        settings.setCompletionGlowEnabled(true)
        #expect(settings.completionGlow == CompletionGlow(theme: .cyberpunk, brightness: 0.55))
    }

    @Test("A theme can be chosen while the glow is off, and shows once it is on")
    func themeIsIndependentOfTheSwitch() {
        var settings = OverheadSettings()
        settings.setCompletionGlowEnabled(false)
        settings.completionGlowTheme = .sunset
        #expect(settings.completionGlow == nil)
        settings.setCompletionGlowEnabled(true)
        #expect(settings.completionGlow?.theme == .sunset)
    }

    @Test("The glow is never drawn fainter than its minimum, or stronger than full")
    func brightnessBounds() {
        var settings = OverheadSettings()
        settings.glowIntensity = 0.1
        #expect(settings.completionGlow?.brightness == CompletionGlow.brightnessRange.lowerBound)
        settings.glowIntensity = 0.6
        #expect(settings.completionGlow?.brightness == 0.6)
        #expect(CompletionGlow(theme: .golden, brightness: 9).brightness == 1)
        #expect(CompletionGlow(theme: .golden, brightness: .nan).brightness == CompletionGlow.defaultBrightness)
    }
}

// MARK: - Saving and upgrading

@Suite("Completion glow: saved settings")
struct CompletionGlowPersistenceTests {
    @Test("Every theme, on or off, comes back after the app restarts")
    func survivesARestart() throws {
        try withIsolatedDefaults { defaults in
            for theme in GlowTheme.allCases {
                for enabled in [true, false] {
                    SettingsStore(defaults: defaults).update {
                        $0.completionGlowTheme = theme
                        $0.setCompletionGlowEnabled(enabled)
                        $0.glowIntensity = 0.45
                    }
                    // A new store is what a new launch reads with.
                    let loaded = SettingsStore(defaults: defaults).load()
                    #expect(loaded.completionGlowTheme == theme)
                    #expect(loaded.completionGlowEnabled == enabled)
                    #expect(loaded.completionGlow == (enabled ? CompletionGlow(theme: theme, brightness: 0.45) : nil))
                }
            }
        }
    }

    @Test("Saving the glow settings leaves the sound settings as they were")
    func savingKeepsSound() throws {
        try withIsolatedDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.update {
                $0.notifications.soundsEnabled = false
                $0.notifications.soundChoice = .glass
                $0.notifications.soundVolume = 0.3
            }
            let sound = store.load().notifications
            store.update {
                $0.setCompletionGlowEnabled(false)
                $0.completionGlowTheme = .emerald
            }
            #expect(SettingsStore(defaults: defaults).load().notifications == sound)
        }
    }

    @Test("An upgrade keeps the glow as it was: the RGB wave at the brightness chosen")
    func upgradeKeepsTheWave() throws {
        let settings = try decode(#"{ "glowIntensity": 0.4 }"#)
        #expect(settings.completionGlow == CompletionGlow(theme: .spectrum, brightness: 0.4))
        #expect(try decode("{}").completionGlow == CompletionGlow(theme: .spectrum, brightness: 0.8))
    }

    @Test("A glow turned off with the old slider stays off after the upgrade")
    func upgradeKeepsItOff() throws {
        let settings = try decode(#"{ "glowIntensity": 0 }"#)
        #expect(!settings.completionGlowEnabled)
        #expect(settings.completionGlow == nil)
        // What the old version wrote is still there, so going back loses nothing.
        #expect(settings.glowIntensity == 0)
        #expect(settings.normalized() == settings)

        // Turning it on again gives a glow that can be seen, in the usual brightness.
        var turnedOn = settings
        turnedOn.setCompletionGlowEnabled(true)
        #expect(turnedOn.completionGlow == CompletionGlow(theme: .spectrum, brightness: 0.8))
    }

    @Test("Once the switch is saved, it decides, whatever the brightness says")
    func theSwitchDecides() throws {
        let on = try decode(#"{ "completionGlowEnabled": true, "glowIntensity": 0 }"#)
        #expect(on.completionGlow?.brightness == CompletionGlow.brightnessRange.lowerBound)
        let off = try decode(#"{ "completionGlowEnabled": false, "glowIntensity": 1, "completionGlowTheme": "aurora" }"#)
        #expect(off.completionGlow == nil)
        #expect(off.completionGlowTheme == .aurora)
    }

    @Test("A theme this version does not know falls back to the RGB wave and costs nothing else")
    func unknownTheme() throws {
        let settings = try decode(#"""
        { "completionGlowTheme": "plasma", "completionGlowEnabled": "sometimes", "glowIntensity": 0.5, "theme": "arctic" }
        """#)
        #expect(settings.completionGlowTheme == .spectrum)
        #expect(settings.completionGlowEnabled)
        #expect(settings.glowIntensity == 0.5)
        #expect(settings.theme == .arctic)
    }

    @Test("Every theme has its own saved name, and it does not change")
    func savedNames() {
        #expect(GlowTheme.allCases.map(\.rawValue) == [
            "spectrum", "golden", "electricBlue", "neonPurple", "crimson",
            "emerald", "cyberpunk", "aurora", "monochrome", "sunset",
        ])
    }
}

// MARK: - The themes

@Suite("Completion glow: themes")
struct GlowThemeTests {
    /// Moments spread over a theme's loop, and well past it.
    private static func moments(_ theme: GlowTheme) -> [TimeInterval] {
        (0..<48).map { theme.cycleSeconds * Double($0) / 16 + 800_000_000 }
    }

    /// The most light a frame can put on the black notch: every fill's
    /// brightest stop, one over the other. The outline is a thin line, not a
    /// fill, and is left out.
    private static func peakLuminance(_ layers: [GlowLayer]) -> Double {
        layers.reduce(0) { below, layer in
            if case .outline = layer.form { return below }
            let brightest = layer.stops
                .map { (light: $0.color.relativeLuminance(), cover: $0.color.alpha * layer.opacity) }
                .max { $0.light * $0.cover + below * (1 - $0.cover) < $1.light * $1.cover + below * (1 - $1.cover) }
            guard let brightest else { return below }
            return brightest.light * brightest.cover + below * (1 - brightest.cover)
        }
    }

    @Test("Ten themes, each with its own name and description")
    func catalogue() {
        #expect(GlowTheme.allCases.count == 10)
        #expect(Set(GlowTheme.allCases.map(\.displayName)).count == 10)
        #expect(Set(GlowTheme.allCases.map(\.summary)).count == 10)
        #expect(GlowTheme.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.summary.isEmpty })
    }

    @Test("RGB Spectrum is the wave the app has always drawn")
    func spectrumIsTheOriginalWave() throws {
        #expect(GlowTheme.spectrum.cycleSeconds == 3)
        let stops = GlowTheme.spectrumStops
        #expect(stops.count == 25)
        for (index, stop) in stops.enumerated() {
            #expect(stop.color == RGBA(hue: Double(index % 12) / 12, saturation: 0.75, brightness: 0.88))
            #expect(abs(stop.location - Double(index) / 24) < 1e-12)
        }
        // One layer, sliding a whole notch width per loop, from phase - 1 to phase + 1.
        for step in 0..<12 {
            let phase = Double(step) / 12
            let layers = GlowTheme.spectrum.layers(at: 3 * phase)
            #expect(layers.count == 1)
            let layer = try #require(layers.first)
            #expect(layer.stops == stops && layer.opacity == 1)
            guard case let .linear(startX, startY, endX, endY) = layer.form else {
                Issue.record("the wave is a straight gradient")
                continue
            }
            #expect(abs(startX - (phase - 1)) < 1e-9 && abs(endX - (phase + 1)) < 1e-9)
            #expect(startY == 0.5 && endY == 0.5)
        }
        // Held still, it rests where it always did.
        #expect(GlowTheme.spectrum.layers(at: nil) == GlowTheme.spectrum.layers(at: 0))
    }

    @Test("Hue, saturation and brightness give the colours they name")
    func hueConversion() {
        #expect(RGBA(hue: 0, saturation: 1, brightness: 1) == RGBA(0xFF0000))
        #expect(RGBA(hue: 1.0 / 3, saturation: 1, brightness: 1) == RGBA(0x00FF00))
        #expect(RGBA(hue: 2.0 / 3, saturation: 1, brightness: 1) == RGBA(0x0000FF))
        #expect(RGBA(hue: 1, saturation: 1, brightness: 1) == RGBA(0xFF0000))
        #expect(RGBA(hue: 0.4, saturation: 0, brightness: 0.5) == RGBA(red: 0.5, green: 0.5, blue: 0.5))
        let yellow = RGBA(hue: 1.0 / 6, saturation: 0.75, brightness: 0.88)
        #expect(abs(yellow.red - 0.88) < 1e-9 && abs(yellow.green - 0.88) < 1e-9 && abs(yellow.blue - 0.22) < 1e-9)
    }

    @Test("Every frame of every theme can be drawn", arguments: GlowTheme.allCases)
    func framesAreWellFormed(theme: GlowTheme) {
        for seconds in Self.moments(theme).map(Optional.some) + [nil] {
            let layers = theme.layers(at: seconds)
            #expect(!layers.isEmpty && layers.count <= 4)
            for layer in layers {
                #expect((0...1).contains(layer.opacity))
                #expect(!layer.stops.isEmpty)
                #expect(layer.stops.allSatisfy { (0...1).contains($0.location) })
                #expect(zip(layer.stops, layer.stops.dropFirst()).allSatisfy { $0.location <= $1.location })
                switch layer.form {
                case let .linear(startX, startY, endX, endY):
                    #expect([startX, startY, endX, endY].allSatisfy { $0.isFinite })
                    #expect(startX != endX || startY != endY)
                    #expect(layer.stops.count >= 2)
                case let .radial(centerX, centerY, radius):
                    #expect([centerX, centerY].allSatisfy { (0...1).contains($0) })
                    #expect(radius > 0 && radius.isFinite)
                    #expect(layer.stops.count >= 2)
                case let .outline(width, blur):
                    #expect(width > 0 && blur >= 0)
                }
            }
        }
    }

    @Test("A gradient that slides always covers the whole notch", arguments: GlowTheme.allCases)
    func slidingGradientsCoverTheNotch(theme: GlowTheme) {
        for seconds in Self.moments(theme) {
            for layer in theme.layers(at: seconds) {
                guard case let .linear(startX, startY, endX, endY) = layer.form, startY == endY,
                      endX - startX == 2 else { continue }
                #expect(startX <= 0 && endX >= 1)
            }
        }
    }

    @Test("Every theme loops without a seam", arguments: GlowTheme.allCases)
    func loops(theme: GlowTheme) {
        // The picture one loop later, and three loops later, is the same picture.
        for step in 0..<16 {
            let seconds = theme.cycleSeconds * Double(step) / 16 + 0.01
            let now = theme.layers(at: seconds)
            #expect(difference(now, theme.layers(at: seconds + theme.cycleSeconds)) < 1e-6)
            #expect(difference(now, theme.layers(at: seconds + theme.cycleSeconds * 3)) < 1e-6)
        }
        // And the last instant of a loop is where the next one begins, so
        // nothing jumps as it comes round.
        let seam = difference(theme.layers(at: theme.cycleSeconds - 1e-6), theme.layers(at: 0))
        #expect(seam < 1e-3, "\(theme) jumps by \(seam) at its seam")
    }

    @Test("Nothing moves in a jerk: one frame to the next is a small change", arguments: GlowTheme.allCases)
    func movesSmoothly(theme: GlowTheme) {
        for step in 0..<120 {
            let seconds = theme.cycleSeconds * Double(step) / 120
            let change = difference(theme.layers(at: seconds), theme.layers(at: seconds + 1.0 / 60))
            #expect(change < 0.2, "\(theme) changes by \(change) in one frame at \(seconds)s")
        }
    }

    @Test("Held still, a theme does not change with time", arguments: GlowTheme.allCases)
    func stillFrame(theme: GlowTheme) {
        let still = theme.layers(at: nil)
        #expect(still == theme.layers(at: nil))
        #expect(still == theme.layers())
        #expect(theme.layers(at: .nan) == still)
        #expect((0..<1).contains(theme.stillPhase))
    }

    @Test("Monochrome is the one theme that never moves; every other does")
    func whichThemesMove() {
        for theme in GlowTheme.allCases {
            let frames = Set(Self.moments(theme).prefix(16).map { "\(theme.layers(at: $0))" })
            #expect(theme.isAnimated == (theme != .monochrome))
            #expect((frames.count > 1) == theme.isAnimated, "\(theme)")
        }
        #expect(GlowTheme.monochrome.layers(at: 12.3) == GlowTheme.monochrome.layers(at: nil))
    }

    @Test("No two themes are drawn the same way")
    func themesDiffer() {
        /// How a theme is built, without its colours or its timing: the kind
        /// of each layer and whether it moves across, changes shape or pulses.
        func build(_ theme: GlowTheme) -> String {
            let early = theme.layers(at: theme.cycleSeconds * 0.13)
            let late = theme.layers(at: theme.cycleSeconds * 0.41)
            return zip(early, late).map { first, second -> String in
                let kind: String
                switch first.form {
                case let .linear(_, startY, _, endY): kind = startY == endY ? "across" : "down"
                case .radial: kind = "radial"
                case .outline: kind = "outline"
                }
                let slides = first.form != second.form
                let reshapes = first.stops != second.stops
                let pulses = first.opacity != second.opacity
                return "\(kind)\(slides ? "+slides" : "")\(reshapes ? "+reshapes" : "")\(pulses ? "+pulses" : "")x\(first.stops.count)"
            }.joined(separator: " | ")
        }
        let builds = GlowTheme.allCases.map(build)
        #expect(Set(builds).count == GlowTheme.allCases.count, "\(builds)")
        // And no theme is another theme's picture either: any two differ
        // clearly somewhere on the notch.
        for (index, first) in GlowTheme.allCases.enumerated() {
            for second in GlowTheme.allCases.dropFirst(index + 1) {
                let apart = difference(first.layers(at: nil), second.layers(at: nil))
                #expect(apart > 0.25, "\(first) and \(second) differ by only \(apart)")
            }
        }
    }

    @Test("Only RGB Spectrum uses the whole rainbow")
    func onlySpectrumIsARainbow() {
        for theme in GlowTheme.allCases where theme != .spectrum {
            #expect(!theme.layers(at: nil).contains { $0.stops == GlowTheme.spectrumStops })
        }
    }

    @Test("Nothing repeats fast enough to flash")
    func noFlashing() {
        for theme in GlowTheme.allCases {
            #expect(theme.cycleSeconds >= GlowTheme.minimumCycleSeconds, "\(theme)")
        }
        // Well under three changes a second, the limit for flashing content.
        #expect(GlowTheme.minimumCycleSeconds >= 1)
        // A layer that pulses never goes dark in between.
        for theme in GlowTheme.allCases {
            let opacities = Self.moments(theme).flatMap { theme.layers(at: $0).map(\.opacity) }
            #expect((opacities.min() ?? 1) >= 0.4, "\(theme)")
        }
    }

    @Test("No theme floods the notch with more light than the original wave", arguments: GlowTheme.allCases)
    func brightnessIsCapped(theme: GlowTheme) {
        let spectrum = Self.peakLuminance(GlowTheme.spectrum.layers(at: nil))
        #expect(spectrum < 0.75)
        for seconds in Self.moments(theme) {
            let peak = Self.peakLuminance(theme.layers(at: seconds))
            #expect(peak <= 0.75, "\(theme) reaches \(peak)")
            #expect(peak > 0.05, "\(theme) would not be seen")
        }
    }

    @Test("Bands of light are spaced evenly and fade to clear between them")
    func bands() {
        let stops = GlowStop.bands(RGBA(0xFF0000), cycles: 4, peak: 0.6, width: 0.5)
        #expect(stops.count == 12)
        #expect(stops.map(\.color.alpha) == [0, 0.6, 0, 0, 0.6, 0, 0, 0.6, 0, 0, 0.6, 0])
        #expect(stops.filter { $0.color.alpha > 0 }.map(\.location) == [0.125, 0.375, 0.625, 0.875])
        let touching = GlowStop.bands(RGBA(0xFF0000), cycles: 2, peak: 1, width: 1)
        #expect(touching.map(\.location) == [0, 0.25, 0.5, 0.75, 1])
        #expect(touching.map(\.color.alpha) == [0, 1, 0, 1, 0])
    }
}
