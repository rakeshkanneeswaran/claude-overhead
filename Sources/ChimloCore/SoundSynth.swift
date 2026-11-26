import Foundation

/// A small synthesizer for Claude Overhead's own sounds. A sound is a list of
/// tones (`SoundPatch`), each a waveform with a pitch, a pitch glide, an
/// envelope and optional vibrato, plus an optional echo. Rendering is pure
/// and deterministic: the same patch always gives the same samples, so the
/// sounds can be tested here and need no audio files.
///
/// Every rendered sound is loudness-matched (`targetRMS`) and kept under a
/// peak ceiling, so one volume setting means the same for all of them.
public enum SoundSynth {
    public static let sampleRate: Double = 44_100
    /// The loudness every sound is rendered at, before the owner's volume.
    public static let targetRMS: Float = 0.19
    /// No sample goes above this.
    public static let peakCeiling: Float = 0.89

    public static func render(_ patch: SoundPatch) -> [Float] {
        let length = Int((patch.duration * sampleRate).rounded(.up)) + 1
        var buffer = [Float](repeating: 0, count: length)
        var noise = NoiseSource(seed: patch.seed)
        for tone in patch.tones {
            add(tone, to: &buffer, noise: &noise)
        }
        if let echo = patch.echo { applyEcho(echo, to: &buffer) }
        finish(&buffer)
        return buffer
    }

    // MARK: Tones

    private static func add(_ tone: Tone, to buffer: inout [Float], noise: inout NoiseSource) {
        let start = Int(tone.start * sampleRate)
        let count = Int(tone.duration * sampleRate)
        guard count > 0, start < buffer.count else { return }
        let end = min(buffer.count, start + count)
        let f0 = tone.frequency
        let f1 = tone.endFrequency ?? tone.frequency
        var phase = tone.phaseOffset
        var modulatorPhase = 0.0
        var filtered = 0.0
        var filtered2 = 0.0
        let gain = tone.gain
        for index in start..<end {
            let t = Double(index - start) / sampleRate
            let progress = t / tone.duration
            // Pitch: an exponential glide, so it sounds even across the range.
            var frequency = f0 * pow(f1 / f0, min(1, progress / max(tone.glideFraction, 0.0001)))
            if let vibrato = tone.vibrato {
                let depth = vibrato.depth * min(1, t / max(vibrato.delay, 0.0001))
                frequency *= pow(2, depth * sin(2 * .pi * vibrato.rate * t) / 12)
            }
            let increment = frequency / sampleRate
            phase += increment
            if phase >= 1 { phase -= floor(phase) }

            var value: Double
            switch tone.waveform {
            case .sine:
                value = sin(2 * .pi * phase)
            case .triangle:
                value = 1 - 4 * abs(phase - 0.5)
            case let .square(duty):
                value = (phase < duty ? 1 : -1)
                value += polyBLEP(phase, increment)
                var falling = phase - duty
                if falling < 0 { falling += 1 }
                value -= polyBLEP(falling, increment)
                // A pulse that is not half and half carries an offset, which
                // each note's envelope would turn into a thump. Take it out.
                value -= 2 * duty - 1
            case .saw:
                value = 2 * phase - 1 - polyBLEP(phase, increment)
            case let .fm(ratio, index):
                modulatorPhase += increment * ratio
                if modulatorPhase >= 1 { modulatorPhase -= floor(modulatorPhase) }
                // The brightness falls away as the note rings, like a struck bar.
                let depth = index * exp(-t / max(tone.decay ?? 0.4, 0.01) * 1.6)
                value = sin(2 * .pi * phase + depth * sin(2 * .pi * modulatorPhase))
            case .noise:
                value = noise.next()
            }

            if let cutoff = tone.lowpass {
                // Two one-pole stages, the cutoff gliding with the tone if asked.
                let hz = cutoff.start * pow(cutoff.end / cutoff.start, progress)
                let k = 1 - exp(-2 * .pi * min(hz, sampleRate * 0.45) / sampleRate)
                filtered += k * (value - filtered)
                filtered2 += k * (filtered - filtered2)
                value = filtered2
            }
            buffer[index] += Float(value * envelope(tone, at: t) * gain)
        }
    }

    /// Attack, then an exponential decay (or a hold), then a release at the end.
    private static func envelope(_ tone: Tone, at t: Double) -> Double {
        let attack = max(tone.attack, 0.0005)
        var level = t < attack ? t / attack : 1
        if let decay = tone.decay, t >= attack {
            level *= tone.sustain + (1 - tone.sustain) * exp(-(t - attack) / decay)
        }
        let remaining = tone.duration - t
        let release = max(tone.release, 0.002)
        if remaining < release { level *= max(0, remaining / release) }
        return level
    }

    /// Smooths a waveform's jumps, so square and saw tones do not alias.
    private static func polyBLEP(_ phase: Double, _ increment: Double) -> Double {
        if phase < increment {
            let x = phase / increment
            return x + x - x * x - 1
        }
        if phase > 1 - increment {
            let x = (phase - 1) / increment
            return x * x + x + x + 1
        }
        return 0
    }

    // MARK: Echo and finishing

    private static func applyEcho(_ echo: Echo, to buffer: inout [Float]) {
        let delay = Int(echo.delay * sampleRate)
        guard delay > 0, delay < buffer.count else { return }
        var damped: Float = 0
        let feedback = Float(min(echo.feedback, 0.85))
        let mix = Float(echo.mix)
        var wet = [Float](repeating: 0, count: buffer.count)
        for index in delay..<buffer.count {
            let input = buffer[index - delay] + wet[index - delay] * feedback
            damped += 0.45 * (input - damped)
            wet[index] = damped
        }
        for index in buffer.indices { buffer[index] += wet[index] * mix }
    }

    /// Removes any offset, matches the loudness, keeps the peak under the
    /// ceiling, and fades both ends so nothing clicks.
    private static func finish(_ buffer: inout [Float]) {
        guard !buffer.isEmpty else { return }
        let mean = buffer.reduce(0, +) / Float(buffer.count)
        for index in buffer.indices { buffer[index] -= mean }
        let rms = activeRMS(buffer)
        guard rms > 0 else { return }
        var scale = targetRMS / rms
        let peak = buffer.map(abs).max() ?? 0
        if peak * scale > peakCeiling * 1.6 {
            // Very peaky sounds are softly limited rather than made quiet.
            scale = peakCeiling * 1.6 / peak
        }
        for index in buffer.indices {
            let value = buffer[index] * scale
            // A soft knee above 0.6 keeps the transients round.
            let magnitude = abs(value)
            let shaped = magnitude <= 0.6 ? magnitude : 0.6 + (peakCeiling - 0.6) * tanh((magnitude - 0.6) / (peakCeiling - 0.6))
            buffer[index] = value < 0 ? -shaped : shaped
        }
        let fadeIn = min(buffer.count, Int(0.002 * sampleRate))
        for index in 0..<fadeIn { buffer[index] *= Float(index) / Float(fadeIn) }
        let fadeOut = min(buffer.count, Int(0.04 * sampleRate))
        for offset in 0..<fadeOut {
            buffer[buffer.count - 1 - offset] *= Float(offset) / Float(fadeOut)
        }
    }

    /// The loudness of the part of a sound that is actually sounding: the
    /// RMS over its loudest 300 ms, so a long tail does not make a short
    /// sound play louder.
    public static func activeRMS(_ samples: [Float]) -> Float {
        let window = min(samples.count, Int(0.3 * sampleRate))
        guard window > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<window { sum += samples[index] * samples[index] }
        var best = sum
        let step = 256
        var index = window
        while index + step <= samples.count {
            for offset in 0..<step {
                let incoming = samples[index + offset]
                let outgoing = samples[index + offset - window]
                sum += incoming * incoming - outgoing * outgoing
            }
            best = max(best, sum)
            index += step
        }
        return (max(best, 0) / Float(window)).squareRoot()
    }

    /// 16-bit mono WAV, for NSSound.
    public static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}

/// Deterministic white noise.
struct NoiseSource {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 2_000_001) / 1_000_000 - 1
    }
}

public struct SoundPatch: Sendable {
    /// No sound is longer than this; a tail past it fades out.
    public static let maxDuration = 1.6

    public var tones: [Tone]
    public var echo: Echo?
    public var seed: UInt64

    public init(_ tones: [Tone], echo: Echo? = nil, seed: UInt64 = 1) {
        self.tones = tones
        self.echo = echo
        self.seed = seed
    }

    /// Seconds, including the echo's tail.
    public var duration: Double {
        let last = min(Self.maxDuration, tones.map { $0.start + $0.duration }.max() ?? 0)
        guard let echo else { return last }
        // Enough repeats to fall below a thousandth.
        let repeats = echo.feedback > 0 ? min(4, log(0.001) / log(max(echo.feedback, 0.05))) : 1
        return min(Self.maxDuration, last + echo.delay * max(1, repeats.rounded(.up)))
    }
}

public struct Echo: Sendable {
    public var delay: Double
    public var feedback: Double
    public var mix: Double
    public init(delay: Double, feedback: Double, mix: Double) {
        self.delay = delay
        self.feedback = feedback
        self.mix = mix
    }
}

public struct Tone: Sendable {
    public enum Waveform: Sendable {
        case sine, triangle, saw, noise
        /// `duty` 0.5 is a square; smaller is thinner and brighter.
        case square(duty: Double)
        /// Frequency modulation: bells, bars and glassy tones.
        case fm(ratio: Double, index: Double)
    }

    public struct Vibrato: Sendable {
        public var rate: Double
        /// Semitones.
        public var depth: Double
        /// Seconds before it is at full depth.
        public var delay: Double
        public init(rate: Double, depth: Double, delay: Double = 0) {
            self.rate = rate
            self.depth = depth
            self.delay = delay
        }
    }

    public struct Sweep: Sendable {
        public var start: Double
        public var end: Double
        public init(_ start: Double, _ end: Double? = nil) {
            self.start = start
            self.end = end ?? start
        }
    }

    public var start: Double
    public var duration: Double
    public var frequency: Double
    public var endFrequency: Double?
    /// The share of the tone the glide takes (1 = all of it).
    public var glideFraction: Double
    public var waveform: Waveform
    public var gain: Double
    public var attack: Double
    /// Time constant of the decay after the attack; nil holds the level.
    public var decay: Double?
    /// Where the decay settles, 0...1.
    public var sustain: Double
    public var release: Double
    public var vibrato: Vibrato?
    public var lowpass: Sweep?
    public var phaseOffset: Double

    public init(
        _ waveform: Waveform,
        _ note: Double,
        at start: Double,
        for duration: Double,
        to endNote: Double? = nil,
        glide: Double = 1,
        gain: Double = 1,
        attack: Double = 0.004,
        decay: Double? = nil,
        sustain: Double = 0,
        release: Double = 0.03,
        vibrato: Vibrato? = nil,
        lowpass: Sweep? = nil,
        phase: Double = 0
    ) {
        self.waveform = waveform
        self.frequency = Tone.hz(note)
        self.endFrequency = endNote.map(Tone.hz)
        self.start = start
        self.duration = duration
        self.glideFraction = glide
        self.gain = gain
        self.attack = attack
        self.decay = decay
        self.sustain = sustain
        self.release = release
        self.vibrato = vibrato
        self.lowpass = lowpass
        self.phaseOffset = phase
    }

    /// A MIDI note number (69 = A4 = 440 Hz) as hertz. Fractions are allowed.
    public static func hz(_ note: Double) -> Double {
        440 * pow(2, (note - 69) / 12)
    }
}
