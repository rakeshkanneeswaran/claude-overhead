import AppKit
import ChimloCore
import Foundation

enum ChiptuneCue {
    case arrival
    case attention
    case success

    var notes: [(frequency: Double, duration: Double)] {
        switch self {
        case .arrival:
            [(392, 0.07), (523.25, 0.09)]
        case .attention:
            [(329.63, 0.09), (0, 0.035), (329.63, 0.09)]
        case .success:
            [(392, 0.07), (523.25, 0.07), (659.25, 0.11)]
        }
    }
}

@MainActor
final class ChiptunePlayer {
    private var activeSound: NSSound?

    /// The built-in chime is a square wave, louder than the system sounds at
    /// the same setting; this keeps the default (0.5) at its old level.
    private static let chimeGain: Float = 0.56

    /// Plays `cue` with the chosen sound at `volume` (0.05...1). NSSound plays
    /// through the current output device under the Mac's own volume and mute.
    func play(
        _ cue: ChiptuneCue,
        choice: NotificationSoundChoice = .chime,
        volume: Double = NotificationSoundVolume.defaultValue
    ) {
        let level = Float(NotificationSoundVolume.clamped(volume))
        let sound: NSSound?
        if let name = choice.systemSoundName {
            // Named sounds are shared instances; a copy can play over itself.
            sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound
            sound?.volume = level
        } else {
            sound = NSSound(data: Self.waveData(for: cue))
            sound?.volume = level * Self.chimeGain
        }
        guard let sound else { return }
        activeSound?.stop()
        activeSound = sound
        sound.play()
    }

    /// Completion sounds made by `SoundSynth`, rendered once each.
    private var synthesized: [String: Data] = [:]

    /// A finished turn's own sound (`CompletionSoundLibrary`). An alert sound
    /// in the collection plays exactly as the alert plays it.
    func playCompletion(_ sound: CompletionSound, volume: Double) {
        guard case .synth = sound.source else {
            if case let .alert(choice) = sound.source { play(.success, choice: choice, volume: volume) }
            return
        }
        let data: Data
        if let cached = synthesized[sound.id] {
            data = cached
        } else {
            data = SoundSynth.wav(sound.samples() ?? [])
            synthesized[sound.id] = data
        }
        guard let player = NSSound(data: data) else { return }
        player.volume = Float(NotificationSoundVolume.clamped(volume))
        activeSound?.stop()
        activeSound = player
        player.play()
    }

    private static func waveData(for cue: ChiptuneCue) -> Data {
        let sampleRate = 22_050
        var samples: [Int16] = []

        for note in cue.notes {
            let count = max(1, Int(note.duration * Double(sampleRate)))
            for index in 0..<count {
                guard note.frequency > 0 else {
                    samples.append(0)
                    continue
                }

                let cycle = (Double(index) * note.frequency / Double(sampleRate))
                    .truncatingRemainder(dividingBy: 1)
                let square = cycle < 0.5 ? 1.0 : -1.0
                let attack = min(1, Double(index) / 70)
                let release = min(1, Double(count - index) / 160)
                let value = square * attack * release * 0.42 * Double(Int16.max)
                samples.append(Int16(value.rounded()))
            }
        }

        let dataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        for sample in samples {
            data.appendLittleEndian(sample)
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
