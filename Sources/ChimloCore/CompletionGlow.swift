import Foundation

/// How the closed notch lights up when Claude finishes a turn.
///
/// `spectrum` is the colour wave the app has always had. The others are not
/// that wave in other colours: each moves in its own way (`layers(at:)`), so
/// a theme can be told apart by its motion as well as by its colour.
public enum GlowTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case spectrum
    case golden
    case electricBlue
    case neonPurple
    case crimson
    case emerald
    case cyberpunk
    case aurora
    case monochrome
    case sunset

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spectrum: "RGB Spectrum"
        case .golden: "Golden Glow"
        case .electricBlue: "Electric Blue"
        case .neonPurple: "Neon Purple"
        case .crimson: "Crimson Red"
        case .emerald: "Emerald Green"
        case .cyberpunk: "Cyberpunk"
        case .aurora: "Aurora"
        case .monochrome: "Monochrome"
        case .sunset: "Sunset"
        }
    }

    /// What the theme does, in a few words, for the picker.
    public var summary: String {
        switch self {
        case .spectrum: "Every colour, flowing sideways"
        case .golden: "Warm gold with a slow shimmer"
        case .electricBlue: "Blue rings pulsing outward"
        case .neonPurple: "Violet edges that breathe"
        case .crimson: "Deep red, rising like embers"
        case .emerald: "A green beam sweeping across"
        case .cyberpunk: "Neon pink and cyan crossing"
        case .aurora: "Slow green and violet curtains"
        case .monochrome: "A still white outline"
        case .sunset: "Orange through pink to purple"
        }
    }

    /// Seconds one loop of the theme's motion takes. Nothing repeats faster
    /// than `minimumCycleSeconds`, so no theme flashes.
    public var cycleSeconds: TimeInterval {
        switch self {
        case .spectrum: 3
        case .golden: 2.6
        case .electricBlue: 2
        case .neonPurple: 3
        case .crimson: 3
        case .emerald: 3.4
        case .cyberpunk: 2.8
        case .aurora: 8
        case .monochrome: 3
        case .sunset: 6
        }
    }

    public static let minimumCycleSeconds: TimeInterval = 2

    /// Whether anything in the theme moves. Monochrome is a still outline,
    /// so it needs no redraw while it shows.
    public var isAnimated: Bool { self != .monochrome }

    /// Where the motion rests when it must not move (Reduce Motion, Focus, a
    /// picker swatch), 0..<1. Chosen so the still picture shows the theme's
    /// colours in the wings beside the camera, which is what a Mac with a
    /// notch can see.
    var stillPhase: Double {
        switch self {
        case .golden: 0.66
        case .emerald: 0.1024
        case .neonPurple: 0.5
        default: 0
        }
    }

    /// How far through its loop the theme is at `seconds`, 0..<1; the still
    /// phase when `seconds` is nil or the theme does not move.
    func phase(at seconds: TimeInterval?) -> Double {
        guard let seconds, seconds.isFinite, isAnimated else { return stillPhase }
        let phase = seconds.truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
        return phase < 0 ? phase + 1 : phase
    }

    /// What to draw at one moment, back to front. `seconds` is any running
    /// clock; nil asks for the still picture. The drawing loops without a
    /// seam every `cycleSeconds`.
    public func layers(at seconds: TimeInterval? = nil) -> [GlowLayer] {
        let p = phase(at: seconds)
        switch self {
        case .spectrum:
            // The original wave: every colour spread across the notch and
            // sliding sideways. Two cycles back to back, so it loops.
            return [.sliding(by: p, stops: Self.spectrumStops)]

        case .golden:
            // Solid gold, with soft highlights gliding across it.
            return [
                .linear(fromX: 0, fromY: 0, toX: 1, toY: 1, stops: GlowStop.evenly([
                    RGBA(0x9A6A12), RGBA(0xD9A532), RGBA(0xB07D1A),
                ])),
                .sliding(by: p / 2, stops: GlowStop.bands(RGBA(0xFFE9A8), cycles: 4, peak: 0.7, width: 0.3)),
            ]

        case .electricBlue:
            // Rings that leave the camera and run out through both wings.
            return [.radial(centerX: 0.5, centerY: 0.5, radius: 0.72, stops: Self.rings(phase: p))]

        case .neonPurple:
            // The notch's edges glow and the glow breathes inward and back.
            let breath = 0.5 - 0.5 * cos(2 * .pi * p)
            let edge = 0.6 - 0.3 * breath
            return [.radial(centerX: 0.5, centerY: 0.5, radius: 0.72, stops: [
                GlowStop(RGBA(0x35166E), 0),
                GlowStop(RGBA(0x4A1D96), edge),
                GlowStop(RGBA(0xA855F7), min(edge + 0.26, 0.97)),
                GlowStop(RGBA(0xD9A8FF), 1),
            ], opacity: 0.78 + 0.22 * breath)]

        case .crimson:
            // Heat sits at the lower edge and rises and settles; embers drift
            // through it.
            let heat = 0.42 + 0.16 * sin(2 * .pi * p)
            return [
                .linear(fromX: 0.5, fromY: 1, toX: 0.5, toY: 0, stops: [
                    GlowStop(RGBA(0xFF4A2E), 0),
                    GlowStop(RGBA(0xD0153A), heat),
                    GlowStop(RGBA(0x5E0A1C), 1),
                ]),
                .sliding(by: p / 3, stops: GlowStop.bands(RGBA(0xFF9A5C), cycles: 6, peak: 0.36, width: 0.2)),
            ]

        case .emerald:
            // One beam crossing the dark notch and coming back. The wings
            // are the lighter part of the ground, so they stay green while
            // the beam is behind the camera.
            let center = 0.5 - 0.5 * cos(2 * .pi * p)
            return [
                .linear(fromX: 0, fromY: 0.5, toX: 1, toY: 0.5, stops: GlowStop.evenly([
                    RGBA(0x0B7350), RGBA(0x064734), RGBA(0x0B7350),
                ])),
                .linear(fromX: center - 0.2, fromY: 0.5, toX: center + 0.2, toY: 0.5, stops: [
                    GlowStop(RGBA(0x3CF0A8, alpha: 0), 0),
                    GlowStop(RGBA(0x7BFFC9, alpha: 0.8), 0.5),
                    GlowStop(RGBA(0x3CF0A8, alpha: 0), 1),
                ]),
            ]

        case .cyberpunk:
            // Pink bands run one way and cyan bands the other, through each
            // other.
            return [
                .linear(fromX: 0, fromY: 0.5, toX: 1, toY: 0.5, stops: GlowStop.evenly([
                    RGBA(0x1B0B3A), RGBA(0x24104F), RGBA(0x1B0B3A),
                ])),
                .sliding(by: p / 3, stops: GlowStop.bands(RGBA(0xFF2E9A), cycles: 6, peak: 0.95, width: 1)),
                .sliding(by: 0.5 - p / 3, stops: GlowStop.bands(RGBA(0x19E6FF), cycles: 6, peak: 0.85, width: 1)),
            ]

        case .aurora:
            // Soft ribbons drifting slowly both ways, fading towards the
            // lower edge as the northern lights fade towards the horizon.
            let veil = 0.35 + 0.15 * sin(4 * .pi * p)
            return [
                .linear(fromX: 0, fromY: 0.5, toX: 1, toY: 0.5, stops: GlowStop.evenly([
                    RGBA(0x04121C), RGBA(0x062030),
                ])),
                .sliding(by: p, stops: Self.auroraStops, opacity: 0.85),
                .sliding(by: 1 - (2 * p).truncatingRemainder(dividingBy: 1), stops: GlowStop.bands(
                    RGBA(0x8CFFD0), cycles: 2, peak: 0.45, width: 0.6
                )),
                .linear(fromX: 0.5, fromY: 0, toX: 0.5, toY: 1, stops: [
                    GlowStop(RGBA(0x020A12, alpha: 0), 0),
                    GlowStop(RGBA(0x020A12, alpha: 0), veil),
                    GlowStop(RGBA(0x020A12, alpha: 0.8), 1),
                ]),
            ]

        case .monochrome:
            // No colour and no movement: the notch's own outline, lit.
            let white = RGBA(0xFFFFFF)
            return [
                .linear(fromX: 0.5, fromY: 0, toX: 0.5, toY: 1, stops: [
                    GlowStop(RGBA(0xFFFFFF, alpha: 0.2), 0),
                    GlowStop(RGBA(0xFFFFFF, alpha: 0.07), 1),
                ]),
                GlowLayer(form: .outline(width: 5, blur: 3), stops: [GlowStop(white, 0)], opacity: 0.55),
                GlowLayer(form: .outline(width: 1.5, blur: 0), stops: [GlowStop(white, 0)], opacity: 0.95),
            ]

        case .sunset:
            // Orange on one side through pink to purple on the other, swaying
            // slowly, with the last light along the lower edge.
            let sway = 0.18 * sin(2 * .pi * p)
            return [
                .linear(fromX: -0.2 + sway, fromY: 0.5, toX: 1.2 + sway, toY: 0.5, stops: GlowStop.evenly([
                    RGBA(0xFF8A3D), RGBA(0xFF5C7A), RGBA(0x8B5CF6),
                ])),
                .linear(fromX: 0.5, fromY: 1, toX: 0.5, toY: 0, stops: [
                    GlowStop(RGBA(0xFFC46B, alpha: 0.5), 0),
                    GlowStop(RGBA(0xFFC46B, alpha: 0), 0.55),
                    GlowStop(RGBA(0xFFC46B, alpha: 0), 1),
                ]),
            ]
        }
    }

    // MARK: Palettes

    /// Every hue twice over. Slightly below full brightness keeps the avatar
    /// and labels on top readable.
    static let spectrumStops: [GlowStop] = GlowStop.evenly((0...24).map {
        RGBA(hue: Double($0 % 12) / 12, saturation: 0.75, brightness: 0.88)
    })

    private static let auroraStops: [GlowStop] = {
        let ribbon = [RGBA(0x35E0A1), RGBA(0x1FC8C8), RGBA(0x6D7CFF), RGBA(0xA06BFF)]
        return GlowStop.evenly(ribbon + ribbon + [ribbon[0]])
    }()

    /// Electric Blue's rings, as stops from the camera outward. `phase` moves
    /// every ring one place further out.
    private static func rings(phase: Double) -> [GlowStop] {
        let deep = RGBA(0x0A1E6E), bright = RGBA(0x2F9BFF), crest = RGBA(0xA9E4FF)
        let samples = 24
        return (0...samples).map { index in
            let location = Double(index) / Double(samples)
            let level = 0.5 + 0.5 * cos(2 * .pi * (2.5 * location - phase))
            return GlowStop(deep.mixed(with: bright, by: level).mixed(with: crest, by: 0.6 * pow(level, 4)), location)
        }
    }
}

/// One colour at one place along a gradient.
public struct GlowStop: Equatable, Sendable {
    public let color: RGBA
    /// 0...1 along the gradient.
    public let location: Double

    public init(_ color: RGBA, _ location: Double) {
        self.color = color
        self.location = min(max(location.isFinite ? location : 0, 0), 1)
    }

    /// The colours spread evenly from the gradient's start to its end.
    static func evenly(_ colors: [RGBA]) -> [GlowStop] {
        guard colors.count > 1 else { return colors.map { GlowStop($0, 0) } }
        return colors.indices.map { GlowStop(colors[$0], Double($0) / Double(colors.count - 1)) }
    }

    /// `cycles` soft bands of one colour with clear gaps between them. Each
    /// band fills `width` of its cycle and reaches `peak` opacity at its
    /// middle.
    static func bands(_ color: RGBA, cycles: Int, peak: Double, width: Double) -> [GlowStop] {
        let clear = RGBA(red: color.red, green: color.green, blue: color.blue, alpha: 0)
        let lit = RGBA(red: color.red, green: color.green, blue: color.blue, alpha: peak)
        let count = max(cycles, 1)
        let length = 1 / Double(count)
        let half = min(max(width, 0.05), 1) / 2
        // Bands that fill their whole cycle touch, so one clear stop between
        // two of them is enough; narrower ones each bring their own.
        let touching = half >= 0.5
        var stops: [GlowStop] = touching ? [GlowStop(clear, 0)] : []
        for cycle in 0..<count {
            let start = Double(cycle) * length
            if !touching { stops.append(GlowStop(clear, start + (0.5 - half) * length)) }
            stops.append(GlowStop(lit, start + 0.5 * length))
            stops.append(GlowStop(clear, start + (0.5 + half) * length))
        }
        return stops
    }
}

/// One fill of the notch's shape. A theme is a few of these, back to front.
public struct GlowLayer: Equatable, Sendable {
    public enum Form: Equatable, Sendable {
        /// A straight gradient between two points of the notch's box, where
        /// (0, 0) is its top left and (1, 1) its bottom right. The points may
        /// lie outside the box.
        case linear(startX: Double, startY: Double, endX: Double, endY: Double)
        /// An oval gradient around a point. `radius` is a fraction of the
        /// box's width and height: 0.5 from the centre touches its edges.
        case radial(centerX: Double, centerY: Double, radius: Double)
        /// The notch's own outline, `width` points wide on its inside and
        /// softened by `blur` points, in the first stop's colour.
        case outline(width: Double, blur: Double)
    }

    public let form: Form
    /// In ascending order of location.
    public let stops: [GlowStop]
    /// 0...1, on top of the stops' own alpha.
    public let opacity: Double

    public init(form: Form, stops: [GlowStop], opacity: Double = 1) {
        self.form = form
        self.stops = stops
        self.opacity = min(max(opacity.isFinite ? opacity : 1, 0), 1)
    }

    static func linear(
        fromX: Double, fromY: Double, toX: Double, toY: Double, stops: [GlowStop], opacity: Double = 1
    ) -> GlowLayer {
        GlowLayer(form: .linear(startX: fromX, startY: fromY, endX: toX, endY: toY), stops: stops, opacity: opacity)
    }

    static func radial(
        centerX: Double, centerY: Double, radius: Double, stops: [GlowStop], opacity: Double = 1
    ) -> GlowLayer {
        GlowLayer(form: .radial(centerX: centerX, centerY: centerY, radius: radius), stops: stops, opacity: opacity)
    }

    /// A gradient two boxes long, moved `offset` of a box to the right
    /// (0...1), so the box always lies inside it. Stops that repeat a whole
    /// number of times along it make a pattern that slides without a seam.
    static func sliding(by offset: Double, stops: [GlowStop], opacity: Double = 1) -> GlowLayer {
        let shift = min(max(offset, 0), 1)
        return .linear(fromX: shift - 1, fromY: 0.5, toX: shift + 1, toY: 0.5, stops: stops, opacity: opacity)
    }
}

extension RGBA {
    /// A colour from hue, saturation and brightness, each 0...1.
    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let wrapped = hue.isFinite ? hue - hue.rounded(.down) : 0
        let saturation = min(max(saturation.isFinite ? saturation : 0, 0), 1)
        let value = min(max(brightness.isFinite ? brightness : 0, 0), 1)
        let sector = wrapped * 6
        let index = Int(sector.rounded(.down)) % 6
        let fraction = sector - sector.rounded(.down)
        let low = value * (1 - saturation)
        let falling = value * (1 - fraction * saturation)
        let rising = value * (1 - (1 - fraction) * saturation)
        let (red, green, blue): (Double, Double, Double) = switch index {
        case 0: (value, rising, low)
        case 1: (falling, value, low)
        case 2: (low, value, rising)
        case 3: (low, falling, value)
        case 4: (rising, low, value)
        default: (value, low, falling)
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// This colour moved `amount` (0...1) of the way to `other`.
    func mixed(with other: RGBA, by amount: Double) -> RGBA {
        let t = min(max(amount.isFinite ? amount : 0, 0), 1)
        return RGBA(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }
}

/// The glow a finished turn shows, as the owner set it up.
public struct CompletionGlow: Equatable, Sendable {
    public let theme: GlowTheme
    /// How strongly it shows, within `brightnessRange`.
    public let brightness: Double

    /// The glow is never drawn fainter than this: below it, it reads as a
    /// fault, not a signal. Off is the switch's job, not the slider's.
    public static let brightnessRange: ClosedRange<Double> = 0.25...1
    public static let defaultBrightness = 0.8

    public init(theme: GlowTheme, brightness: Double) {
        self.theme = theme
        let finite = brightness.isFinite ? brightness : Self.defaultBrightness
        self.brightness = min(max(finite, Self.brightnessRange.lowerBound), Self.brightnessRange.upperBound)
    }
}

extension OverheadSettings {
    /// What a finished turn lights the closed notch with, or nil when the
    /// glow is switched off. Sound plays no part in it: a session's bell and
    /// the glow are two separate choices, and neither changes the other.
    public var completionGlow: CompletionGlow? {
        completionGlowEnabled ? CompletionGlow(theme: completionGlowTheme, brightness: glowIntensity) : nil
    }

    /// The glow's own switch. Turning it off keeps the theme and brightness
    /// for when it is turned on again. Turning it on with a brightness left
    /// at zero (how the glow was turned off before the switch existed) goes
    /// back to the usual brightness, since zero was never a brightness.
    public mutating func setCompletionGlowEnabled(_ enabled: Bool) {
        completionGlowEnabled = enabled
        if enabled, glowIntensity < CompletionGlow.brightnessRange.lowerBound {
            glowIntensity = CompletionGlow.defaultBrightness
        }
    }
}
