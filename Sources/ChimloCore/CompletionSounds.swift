import Foundation

/// The sounds a finished turn can play, separate from the alert sound that
/// permission requests, questions and failures use (`NotificationSoundChoice`).
/// Until the owner picks one, a finished turn plays the alert sound, as it
/// always has.
///
/// The five alert sounds are in the collection too, under their own ids, so
/// any of them can be the completion sound alone. Every other sound is
/// synthesized by `SoundSynth`: original, made here, nothing to license.
public enum CompletionSoundCategory: String, CaseIterable, Identifiable, Sendable {
    case victory, retro, minimal, futuristic, playful

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .victory: "Victory & Achievement"
        case .retro: "Retro & Gaming"
        case .minimal: "Minimal & Professional"
        case .futuristic: "Futuristic & Cinematic"
        case .playful: "Fun & Playful"
        }
    }
}

public struct CompletionSound: Identifiable, Sendable {
    public enum Source: Sendable {
        /// One of the alert sounds, played exactly as the alert plays it.
        case alert(NotificationSoundChoice)
        case synth(SoundPatch)
    }

    public let id: String
    public let name: String
    public let category: CompletionSoundCategory
    public let source: Source

    /// Rendered samples, for a synthesized sound; nil for an alert sound.
    public func samples() -> [Float]? {
        guard case let .synth(patch) = source else { return nil }
        return SoundSynth.render(patch)
    }
}

public enum CompletionSoundLibrary {
    /// The id stored when no completion sound was chosen: finished turns play
    /// the alert sound.
    public static let sameAsAlert = ""

    public static func sound(id: String) -> CompletionSound? {
        byID[id]
    }

    public static func sounds(in category: CompletionSoundCategory) -> [CompletionSound] {
        all.filter { $0.category == category }
    }

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static let all: [CompletionSound] = victory + retro + minimal + futuristic + playful

    // MARK: Instruments

    private static func brass(_ note: Double, at start: Double, for duration: Double, gain: Double = 1, vibrato: Bool = false) -> [Tone] {
        let wobble = vibrato ? Tone.Vibrato(rate: 5.4, depth: 0.18, delay: 0.18) : nil
        return [
            Tone(.square(duty: 0.25), note, at: start, for: duration, gain: 0.55 * gain, attack: 0.018, decay: 0.5, sustain: 0.6,
                 release: 0.06, vibrato: wobble, lowpass: .init(1400, 3200)),
            Tone(.saw, note + 0.06, at: start, for: duration, gain: 0.35 * gain, attack: 0.025, decay: 0.5, sustain: 0.55,
                 release: 0.06, vibrato: wobble, lowpass: .init(1100, 2600)),
        ]
    }

    private static func bell(_ note: Double, at start: Double, decay: Double, gain: Double = 1, ratio: Double = 3.5, index: Double = 2.2) -> Tone {
        Tone(.fm(ratio: ratio, index: index), note, at: start, for: decay * 2.6, gain: gain, attack: 0.002, decay: decay, release: decay * 0.6)
    }

    private static func pluck(_ note: Double, at start: Double, decay: Double = 0.3, gain: Double = 1) -> [Tone] {
        [
            Tone(.triangle, note, at: start, for: decay * 2.6, gain: 0.8 * gain, attack: 0.002, decay: decay, release: decay * 0.6),
            Tone(.sine, note + 12, at: start, for: decay * 2, gain: 0.25 * gain, attack: 0.002, decay: decay * 0.5, release: 0.04),
        ]
    }

    private static func blip(_ note: Double, at start: Double, for duration: Double, duty: Double = 0.5, gain: Double = 1, decay: Double? = nil) -> Tone {
        Tone(.square(duty: duty), note, at: start, for: duration, gain: gain, attack: 0.002, decay: decay, release: 0.008)
    }

    private static func thump(_ note: Double, at start: Double, gain: Double = 1) -> Tone {
        Tone(.sine, note + 7, at: start, for: 0.5, to: note, glide: 0.2, gain: gain, attack: 0.003, decay: 0.16, release: 0.05)
    }

    private static func snare(at start: Double, gain: Double = 0.4) -> Tone {
        Tone(.noise, 60, at: start, for: 0.16, gain: gain, attack: 0.001, decay: 0.045, release: 0.02, lowpass: .init(6000, 2500))
    }

    // MARK: Victory & Achievement

    private static let victory: [CompletionSound] = [
        CompletionSound(id: "victory.fanfare", name: "Victory Fanfare", category: .victory, source: .synth(SoundPatch(
            brass(67, at: 0, for: 0.12) + brass(72, at: 0.11, for: 0.12) + brass(76, at: 0.22, for: 0.12)
                + brass(79, at: 0.33, for: 0.6, vibrato: true) + brass(76, at: 0.33, for: 0.6, gain: 0.5) + brass(72, at: 0.33, for: 0.6, gain: 0.45)
                + [thump(43, at: 0.33, gain: 0.9)],
            echo: Echo(delay: 0.11, feedback: 0.22, mix: 0.18)
        ))),
        CompletionSound(id: "victory.mission", name: "Mission Complete", category: .victory, source: .synth(SoundPatch(
            [70.0, 74, 77].flatMap { brass($0, at: 0, for: 0.22, gain: 0.7) }
                + [72.0, 76, 79, 84].flatMap { brass($0, at: 0.24, for: 0.72, gain: 0.75, vibrato: $0 == 84) }
                + [thump(36, at: 0.24, gain: 1.1), snare(at: 0.24, gain: 0.35)],
            echo: Echo(delay: 0.14, feedback: 0.2, mix: 0.16)
        ))),
        CompletionSound(id: "victory.level-up", name: "Level Up", category: .victory, source: .synth(SoundPatch(
            [72.0, 76, 79, 84, 88, 91].enumerated().map { blip($0.element, at: Double($0.offset) * 0.055, for: 0.07, gain: 0.7, decay: 0.08) }
                + [blip(96, at: 0.33, for: 0.4, duty: 0.25, gain: 0.8, decay: 0.2),
                   Tone(.triangle, 84, at: 0.33, for: 0.4, gain: 0.5, decay: 0.22, release: 0.05)],
            echo: Echo(delay: 0.09, feedback: 0.3, mix: 0.25)
        ))),
        CompletionSound(id: "victory.achievement", name: "Achievement Unlocked", category: .victory, source: .synth(SoundPatch(
            [76.0, 83, 88].flatMap { note in
                [Tone(.saw, note - 0.07, at: 0, for: 0.75, gain: 0.18, attack: 0.15, release: 0.25, lowpass: .init(500, 2600)),
                 Tone(.saw, note + 0.07, at: 0, for: 0.75, gain: 0.18, attack: 0.15, release: 0.25, lowpass: .init(500, 2600))]
            } + [bell(88, at: 0.06, decay: 0.45, gain: 0.8), bell(95, at: 0.2, decay: 0.5, gain: 0.7),
                 Tone(.sine, 100, at: 0.36, for: 0.6, gain: 0.3, decay: 0.25, release: 0.08)],
            echo: Echo(delay: 0.14, feedback: 0.35, mix: 0.28)
        ))),
        CompletionSound(id: "victory.trophy", name: "Trophy", category: .victory, source: .synth(SoundPatch(
            [Tone(.triangle, 72, at: 0, for: 0.1, gain: 0.8, release: 0.02),
             Tone(.triangle, 79, at: 0.1, for: 0.1, gain: 0.8, release: 0.02),
             Tone(.triangle, 88, at: 0.2, for: 0.6, gain: 0.9, decay: 0.5, sustain: 0.3, release: 0.12,
                  vibrato: .init(rate: 5.5, depth: 0.3, delay: 0.15)),
             bell(96, at: 0.2, decay: 0.55, gain: 0.35)],
            echo: Echo(delay: 0.12, feedback: 0.25, mix: 0.2)
        ))),
        CompletionSound(id: "victory.quest", name: "Quest Complete", category: .victory, source: .synth(SoundPatch(
            [74.0, 78, 81, 86, 90].enumerated().flatMap { pluck($0.element, at: Double($0.offset) * 0.045, decay: 0.3, gain: 0.7) }
                + pluck(93, at: 0.225, decay: 0.55),
            echo: Echo(delay: 0.12, feedback: 0.25, mix: 0.2)
        ))),
    ]

    // MARK: Retro & Gaming

    private static let retro: [CompletionSound] = [
        CompletionSound(id: NotificationSoundChoice.chime.rawValue, name: NotificationSoundChoice.chime.displayName, category: .retro, source: .alert(.chime)),
        CompletionSound(id: "retro.coin", name: "Coin", category: .retro, source: .synth(SoundPatch(
            [blip(88, at: 0, for: 0.04, duty: 0.25, gain: 0.8), blip(91, at: 0.04, for: 0.04, duty: 0.25, gain: 0.8),
             blip(96, at: 0.08, for: 0.32, duty: 0.25, gain: 0.9, decay: 0.12)]
        ))),
        CompletionSound(id: "retro.power-up", name: "Power-Up", category: .retro, source: .synth(SoundPatch(
            [60.0, 62, 64, 67, 69, 72, 74, 76, 79, 81, 84, 86, 88, 91].enumerated().map {
                blip($0.element, at: Double($0.offset) * 0.034, for: 0.036, gain: 0.65)
            } + [Tone(.triangle, 48, at: 0, for: 0.48, to: 72, gain: 0.5, release: 0.03),
                 blip(96, at: 0.48, for: 0.22, duty: 0.25, gain: 0.7, decay: 0.1)]
        ))),
        CompletionSound(id: "retro.extra-life", name: "Extra Life", category: .retro, source: .synth(SoundPatch(
            [84.0, 88, 91, 88, 91].enumerated().map { blip($0.element, at: Double($0.offset) * 0.07, for: 0.068, gain: 0.7) }
                + [blip(96, at: 0.35, for: 0.3, gain: 0.75, decay: 0.15)]
        ))),
        CompletionSound(id: "retro.stage-clear", name: "Stage Clear", category: .retro, source: .synth(SoundPatch(
            [(79.0, 0.0, 0.09), (81, 0.09, 0.09), (83, 0.18, 0.09), (86, 0.27, 0.17), (83, 0.45, 0.09), (86, 0.54, 0.45)].map {
                blip($0.0, at: $0.1, for: $0.2, duty: 0.25, gain: 0.6, decay: $0.2 > 0.3 ? 0.3 : nil)
            } + [(43.0, 0.0, 0.26), (47, 0.27, 0.26), (50, 0.54, 0.45)].map {
                Tone(.triangle, $0.0, at: $0.1, for: $0.2, gain: 0.7, release: 0.03)
            } + [snare(at: 0.54, gain: 0.35)]
        ))),
        CompletionSound(id: "retro.treasure", name: "Treasure", category: .retro, source: .synth(SoundPatch(
            [(84.0, 0.0), (79, 0.07), (84, 0.14), (88, 0.21)].flatMap {
                [Tone(.triangle, $0.0, at: $0.1, for: 0.07, gain: 0.7, release: 0.01), blip($0.0 + 12, at: $0.1, for: 0.07, duty: 0.125, gain: 0.2)]
            } + [Tone(.triangle, 91, at: 0.28, for: 0.45, gain: 0.8, decay: 0.35, sustain: 0.2, release: 0.08,
                      vibrato: .init(rate: 6, depth: 0.25, delay: 0.12)),
                 blip(103, at: 0.28, for: 0.45, duty: 0.125, gain: 0.18, decay: 0.15),
                 Tone(.sine, 103, at: 0.32, for: 0.3, gain: 0.25, decay: 0.12)]
        ))),
        CompletionSound(id: "retro.combo", name: "Combo", category: .retro, source: .synth(SoundPatch(
            (0..<4).flatMap { step -> [Tone] in
                let note = 81 + Double(step) * 3
                return [Tone(.square(duty: 0.5), note, at: Double(step) * 0.08, for: 0.075, to: note - 4, glide: 0.4, gain: 0.6, decay: 0.05, release: 0.01),
                        Tone(.noise, 60, at: Double(step) * 0.08, for: 0.012, gain: 0.25, release: 0.004, lowpass: .init(9000))]
            } + [blip(96, at: 0.32, for: 0.22, duty: 0.25, gain: 0.6, decay: 0.09)]
        ))),
    ]

    // MARK: Minimal & Professional

    private static let minimal: [CompletionSound] = [
        CompletionSound(id: NotificationSoundChoice.tink.rawValue, name: NotificationSoundChoice.tink.displayName, category: .minimal, source: .alert(.tink)),
        CompletionSound(id: NotificationSoundChoice.pop.rawValue, name: NotificationSoundChoice.pop.displayName, category: .minimal, source: .alert(.pop)),
        CompletionSound(id: NotificationSoundChoice.glass.rawValue, name: NotificationSoundChoice.glass.displayName, category: .minimal, source: .alert(.glass)),
        CompletionSound(id: NotificationSoundChoice.purr.rawValue, name: NotificationSoundChoice.purr.displayName, category: .minimal, source: .alert(.purr)),
        CompletionSound(id: "minimal.soft-bell", name: "Soft Bell", category: .minimal, source: .synth(SoundPatch(
            [bell(81, at: 0, decay: 0.42, ratio: 2, index: 1.2), Tone(.sine, 93, at: 0, for: 0.8, gain: 0.15, decay: 0.28)]
        ))),
        CompletionSound(id: "minimal.two-tone", name: "Two-Tone", category: .minimal, source: .synth(SoundPatch(
            [Tone(.sine, 76, at: 0, for: 0.2, gain: 0.9, attack: 0.008, decay: 0.12, release: 0.04),
             Tone(.sine, 88, at: 0, for: 0.2, gain: 0.1, attack: 0.008, decay: 0.08, release: 0.04),
             Tone(.sine, 81, at: 0.14, for: 0.55, gain: 0.9, attack: 0.008, decay: 0.22, release: 0.06),
             Tone(.sine, 93, at: 0.14, for: 0.4, gain: 0.1, attack: 0.008, decay: 0.12, release: 0.05)]
        ))),
        CompletionSound(id: "minimal.marimba", name: "Marimba", category: .minimal, source: .synth(SoundPatch(
            [(79.0, 0.0), (83, 0.08), (86, 0.16)].map { bell($0.0, at: $0.1, decay: 0.14, ratio: 4, index: 1.4) }
        ))),
        CompletionSound(id: "minimal.crystal", name: "Crystal", category: .minimal, source: .synth(SoundPatch(
            [bell(96, at: 0, decay: 0.35, ratio: 3, index: 0.8), Tone(.sine, 103, at: 0.03, for: 0.6, gain: 0.4, decay: 0.25)],
            echo: Echo(delay: 0.07, feedback: 0.3, mix: 0.3)
        ))),
    ]

    // MARK: Futuristic & Cinematic

    private static let futuristic: [CompletionSound] = [
        CompletionSound(id: "futuristic.warp", name: "Warp", category: .futuristic, source: .synth(SoundPatch(
            [Tone(.noise, 60, at: 0, for: 0.45, gain: 0.5, attack: 0.3, release: 0.05, lowpass: .init(300, 6000)),
             Tone(.sine, 60, at: 0, for: 0.45, to: 96, gain: 0.45, attack: 0.3, release: 0.04),
             bell(91, at: 0.45, decay: 0.3, gain: 1, ratio: 1.5, index: 1)],
            echo: Echo(delay: 0.1, feedback: 0.35, mix: 0.3)
        ))),
        CompletionSound(id: "futuristic.hologram", name: "Hologram", category: .futuristic, source: .synth(SoundPatch(
            [64.0, 71, 76].flatMap { note in
                [-0.08, 0.08].map { detune in
                    Tone(.saw, note + detune, at: 0, for: 0.9, gain: 0.22, attack: 0.2, release: 0.3,
                         vibrato: .init(rate: 4, depth: 0.08), lowpass: .init(400, 3000))
                }
            } + [bell(88, at: 0.35, decay: 0.4, gain: 0.5, ratio: 1.5, index: 1.4)]
        ))),
        CompletionSound(id: "futuristic.transmission", name: "Transmission", category: .futuristic, source: .synth(SoundPatch(
            [96.0, 91, 98, 93, 100, 95, 103, 98].enumerated().map { blip($0.element, at: Double($0.offset) * 0.045, for: 0.03, duty: 0.25, gain: 0.35) }
                + [Tone(.sine, 84, at: 0.42, for: 0.12, gain: 0.8, attack: 0.005, decay: 0.08),
                   Tone(.sine, 91, at: 0.52, for: 0.4, gain: 0.85, attack: 0.005, decay: 0.2)]
        ))),
        CompletionSound(id: "futuristic.swell", name: "Synth Swell", category: .futuristic, source: .synth(SoundPatch(
            [60.0, 67, 72, 76].flatMap { note in
                [-0.06, 0.06].map { Tone(.saw, note + $0, at: 0, for: 0.85, gain: 0.2, attack: 0.5, release: 0.3, lowpass: .init(200, 4000)) }
            } + [Tone(.noise, 60, at: 0, for: 0.56, gain: 0.22, attack: 0.5, release: 0.04, lowpass: .init(500, 8000)),
                 Tone(.sine, 43, at: 0.55, for: 0.7, to: 33, glide: 0.4, gain: 1.2, attack: 0.004, decay: 0.3, release: 0.08)]
        ))),
        CompletionSound(id: "futuristic.orbit", name: "Orbit", category: .futuristic, source: .synth(SoundPatch(
            [Tone(.fm(ratio: 1.41, index: 2.5), 84, at: 0, for: 1.0, gain: 0.9, decay: 0.55, release: 0.1, vibrato: .init(rate: 6, depth: 0.15)),
             Tone(.fm(ratio: 1.41, index: 2.0), 91, at: 0.12, for: 0.9, gain: 0.7, decay: 0.5, release: 0.1, vibrato: .init(rate: 6, depth: 0.15))],
            echo: Echo(delay: 0.16, feedback: 0.42, mix: 0.35)
        ))),
        CompletionSound(id: "futuristic.online", name: "Systems Online", category: .futuristic, source: .synth(SoundPatch(
            [(72.0, 0.0, 0.1, 0.08), (79, 0.11, 0.1, 0.08), (86, 0.22, 0.45, 0.25)].flatMap {
                [Tone(.fm(ratio: 2, index: 0.6), $0.0, at: $0.1, for: $0.2, gain: 0.85, decay: $0.3, release: 0.03),
                 blip($0.0 + 12, at: $0.1, for: $0.2, duty: 0.125, gain: 0.12, decay: $0.3)]
            }
        ))),
    ]

    // MARK: Fun & Playful

    private static let playful: [CompletionSound] = [
        CompletionSound(id: "playful.bubble", name: "Bubble Pop", category: .playful, source: .synth(SoundPatch(
            [(67.0, 91.0, 0.0, 0.09), (74, 98, 0.12, 0.09), (79, 103, 0.22, 0.07)].map {
                Tone(.sine, $0.0, at: $0.2, for: $0.3, to: $0.1, glide: 0.6, gain: 0.9, attack: 0.003, decay: 0.05, release: 0.01)
            }
        ))),
        CompletionSound(id: "playful.boing", name: "Boing", category: .playful, source: .synth(SoundPatch(
            [Tone(.sine, 79, at: 0, for: 0.5, to: 60, gain: 0.9, attack: 0.003, decay: 0.3, release: 0.06, vibrato: .init(rate: 14, depth: 1.2)),
             Tone(.triangle, 67, at: 0, for: 0.5, to: 48, gain: 0.35, attack: 0.003, decay: 0.3, release: 0.06, vibrato: .init(rate: 14, depth: 1.2))]
        ))),
        CompletionSound(id: "playful.ta-da", name: "Ta-Da", category: .playful, source: .synth(SoundPatch(
            [67.0, 71, 74].flatMap { [blip($0, at: 0, for: 0.12, duty: 0.125, gain: 0.35, decay: 0.08),
                                      Tone(.saw, $0, at: 0, for: 0.12, gain: 0.25, decay: 0.08, lowpass: .init(2200))] }
                + [72.0, 76, 79, 84].flatMap { [Tone(.square(duty: 0.125), $0, at: 0.16, for: 0.6, gain: 0.35, attack: 0.002, decay: 0.45, sustain: 0.3, release: 0.05),
                                                Tone(.saw, $0, at: 0.16, for: 0.6, gain: 0.25, decay: 0.45, sustain: 0.3,
                                                     vibrato: .init(rate: 5.5, depth: 0.2, delay: 0.2), lowpass: .init(2400))] }
        ))),
        CompletionSound(id: "playful.slide-whistle", name: "Slide Whistle", category: .playful, source: .synth(SoundPatch(
            [Tone(.sine, 72, at: 0, for: 0.5, to: 96, glide: 0.85, gain: 1, attack: 0.03, release: 0.08, vibrato: .init(rate: 7, depth: 0.25)),
             Tone(.noise, 60, at: 0, for: 0.5, gain: 0.05, attack: 0.03, release: 0.08, lowpass: .init(3000))]
        ))),
        CompletionSound(id: "playful.chirp", name: "Chirp", category: .playful, source: .synth(SoundPatch(
            [(96.0, 101.0, 0.0, 0.05), (96, 101, 0.07, 0.05), (98, 105, 0.14, 0.08)].map {
                Tone(.sine, $0.0, at: $0.2, for: $0.3, to: $0.1, gain: 0.9, attack: 0.004, decay: 0.04, release: 0.01)
            }
        ))),
        CompletionSound(id: "playful.party-horn", name: "Party Horn", category: .playful, source: .synth(SoundPatch(
            [Tone(.saw, 69, at: 0, for: 0.45, to: 72, glide: 0.2, gain: 0.7, attack: 0.015, release: 0.06,
                  vibrato: .init(rate: 18, depth: 0.35), lowpass: .init(1800)),
             bell(100, at: 0.45, decay: 0.12, gain: 0.5), bell(103, at: 0.52, decay: 0.12, gain: 0.45),
             bell(98, at: 0.59, decay: 0.15, gain: 0.4)]
        ))),
    ]
}

extension NotificationPreferences {
    /// What a finished turn plays: the chosen completion sound, or nil for
    /// the alert sound (no choice made, or an id this version does not know).
    public var completionSoundOverride: CompletionSound? {
        CompletionSoundLibrary.sound(id: completionSound)
    }
}
