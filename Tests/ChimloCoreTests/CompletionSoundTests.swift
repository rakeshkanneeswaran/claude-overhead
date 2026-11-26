import ChimloCore
import Foundation
import Testing

@Suite("Completion sounds")
struct CompletionSoundTests {
    private static let synthesized: [(CompletionSound, [Float])] = CompletionSoundLibrary.all.compactMap { sound in
        sound.samples().map { (sound, $0) }
    }

    @Test("At least 30 sounds, in the five groups, with unique ids and names")
    func collection() {
        let all = CompletionSoundLibrary.all
        #expect(all.count >= 30)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        for category in CompletionSoundCategory.allCases {
            #expect(CompletionSoundLibrary.sounds(in: category).count >= 5, "\(category)")
        }
        #expect(CompletionSoundCategory.allCases.map(\.displayName) == [
            "Victory & Achievement", "Retro & Gaming", "Minimal & Professional", "Futuristic & Cinematic", "Fun & Playful",
        ])
    }

    @Test("The five existing sounds are all there, played as before")
    func existingSoundsKept() throws {
        for choice in NotificationSoundChoice.allCases {
            let sound = try #require(CompletionSoundLibrary.sound(id: choice.rawValue), "\(choice)")
            guard case let .alert(played) = sound.source else {
                Issue.record("\(choice) is no longer the alert sound")
                continue
            }
            #expect(played == choice)
            #expect(sound.samples() == nil)
        }
    }

    @Test("Every new sound is short, not silent, matched in loudness and never clips")
    func quality() {
        #expect(Self.synthesized.count >= 25)
        for (sound, samples) in Self.synthesized {
            let seconds = Double(samples.count) / SoundSynth.sampleRate
            #expect(seconds >= 0.15 && seconds <= SoundPatch.maxDuration + 0.01, "\(sound.id): \(seconds) s")
            #expect(samples.allSatisfy { $0.isFinite }, "\(sound.id) has a non-number")
            let peak = samples.map(abs).max() ?? 0
            #expect(peak <= SoundSynth.peakCeiling, "\(sound.id) peaks at \(peak)")
            let rms = SoundSynth.activeRMS(samples)
            #expect(abs(rms - SoundSynth.targetRMS) / SoundSynth.targetRMS < 0.06, "\(sound.id) loudness \(rms)")
            // Both ends fade, so nothing clicks.
            #expect(abs(samples.first ?? 1) < 0.001 && abs(samples.last ?? 1) < 0.001, "\(sound.id) does not fade")
            // No offset, which would thump.
            let mean = samples.reduce(0, +) / Float(samples.count)
            #expect(abs(mean) < 0.002, "\(sound.id) offset \(mean)")
        }
    }

    @Test("A sound renders the same every time")
    func deterministic() throws {
        let sound = try #require(CompletionSoundLibrary.sound(id: "victory.fanfare"))
        #expect(sound.samples() == sound.samples())
    }

    @Test("No two sounds are the same sound")
    func distinct() {
        // How the sound moves (loudness over time) and how bright it is
        // (zero crossings), in 24 slices of its length.
        func fingerprint(_ samples: [Float]) -> [Double] {
            let slices = 24
            let size = max(1, samples.count / slices)
            var print: [Double] = []
            for slice in 0..<slices {
                let part = samples[min(samples.count, slice * size)..<min(samples.count, (slice + 1) * size)]
                let energy = part.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, part.count))
                var crossings = 0
                var previous: Float = 0
                for value in part {
                    if (value >= 0) != (previous >= 0) { crossings += 1 }
                    previous = value
                }
                print.append(energy.squareRoot() * 4)
                print.append(Double(crossings) / Double(max(1, part.count)))
            }
            print.append(Double(samples.count) / SoundSynth.sampleRate)
            return print
        }
        let prints = Self.synthesized.map { ($0.0.id, fingerprint($0.1)) }
        for (index, first) in prints.enumerated() {
            for second in prints[(index + 1)...] {
                let distance = zip(first.1, second.1).reduce(0) { $0 + abs($1.0 - $1.1) }
                #expect(distance > 0.4, "\(first.0) and \(second.0) sound alike (\(distance))")
            }
        }
    }

    @Test("A WAV of a sound is a valid 44.1 kHz mono file of the right length")
    func wav() throws {
        let samples = try #require(CompletionSoundLibrary.sound(id: "retro.coin")?.samples())
        let data = SoundSynth.wav(samples)
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    }

    @Test("Until one is chosen, a finished turn plays the alert sound, as before")
    func defaultIsTheAlertSound() throws {
        let defaults = NotificationPreferences()
        #expect(defaults.completionSound == CompletionSoundLibrary.sameAsAlert)
        #expect(defaults.completionSoundOverride == nil)
        // Settings saved before completion sounds existed.
        let older = try JSONDecoder().decode(NotificationPreferences.self, from: Data(#"{"soundChoice":"glass","soundVolume":0.8}"#.utf8))
        #expect(older.completionSound == CompletionSoundLibrary.sameAsAlert)
        #expect(older.soundChoice == .glass)
        #expect(older.soundVolume == 0.8)
    }

    @Test("A chosen completion sound is kept, and leaves the alert sound and the volume alone")
    func persistence() throws {
        var settings = OverheadSettings()
        settings.notifications.soundChoice = .pop
        settings.notifications.soundVolume = 0.7
        settings.notifications.completionSound = "retro.power-up"
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.notifications.completionSound == "retro.power-up")
        #expect(decoded.notifications.completionSoundOverride?.name == "Power-Up")
        #expect(decoded.notifications.soundChoice == .pop)
        #expect(decoded.notifications.soundVolume == 0.7)
    }

    @Test("An id from a newer version is kept, and plays the alert sound here")
    func unknownID() throws {
        let data = Data(#"{"completionSound":"future.sound"}"#.utf8)
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: data)
        #expect(decoded.completionSound == "future.sound")
        #expect(decoded.completionSoundOverride == nil)
        let again = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(decoded))
        #expect(again.completionSound == "future.sound")
    }

    @Test("The completion sound and the completion glow do not touch each other")
    func independentOfGlow() {
        var settings = OverheadSettings()
        let glow = settings.completionGlow
        let theme = settings.completionGlowTheme
        settings.notifications.completionSound = "victory.fanfare"
        #expect(settings.completionGlow == glow)
        #expect(settings.completionGlowTheme == theme)
        settings.setCompletionGlowEnabled(false)
        #expect(settings.notifications.completionSound == "victory.fanfare")
    }

    @Test("Search finds it")
    func searchable() {
        for query in ["completion sound", "fanfare", "coin", "8-bit"] {
            #expect(SettingsCatalog.search(query).contains { $0.id == "completionSound" }, "\(query)")
        }
    }
}

/// The app half: it reads the app target's source, as the other wiring suites do.
@Suite("Completion sounds: app wiring")
struct CompletionSoundWiringTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    private static func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) is missing")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    @Test("Only a finished turn plays the completion sound; alerts keep the alert sound")
    func onlyCompletions() throws {
        let model = try Self.source("ApplicationModel.swift")
        let play = try Self.body(of: "private func playSound(_ cue: ChiptuneCue) {", in: model)
        #expect(play.contains("if cue == .success, let completionSound {"))
        #expect(play.contains("chiptunePlayer.play(cue, choice: soundChoice, volume: soundVolume)"))
        // One volume for every sound.
        #expect(play.contains("chiptunePlayer.playCompletion(completionSound, volume: soundVolume)"))
    }

    @Test("The glow never reads the completion sound, nor the sound the glow")
    func glowIndependent() throws {
        let model = try Self.source("ApplicationModel.swift")
        let glow = try Self.body(of: "private func flashCompletionGlow() {", in: model)
        #expect(!glow.contains("completionSound"))
        let play = try Self.body(of: "private func playSound(_ cue: ChiptuneCue) {", in: model)
        #expect(!play.lowercased().contains("glow"))
        let player = try Self.source("ChiptunePlayer.swift")
        #expect(!player.lowercased().contains("glow"))
    }

    @Test("Each sound can be heard before it is chosen")
    func previews() throws {
        let picker = try Self.source("CompletionSoundPicker.swift")
        #expect(picker.contains("Button { preview(id) }"))
        #expect(picker.contains("Button { choose(id) }"))
        let settings = try Self.source("CompanionSettings.swift")
        #expect(settings.contains("settings.settings.notifications.completionSound = id"))
        #expect(settings.contains("preview: previewCompletion"))
    }
}
