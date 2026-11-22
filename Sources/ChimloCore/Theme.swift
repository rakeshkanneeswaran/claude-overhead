import Foundation

/// A colour as plain sRGB components in 0...1.
///
/// Core stays free of SwiftUI and AppKit so themes can be tested headlessly;
/// the app maps these values to `Color` at the edge.
public struct RGBA: Codable, Equatable, Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// Builds a colour from `0xRRGGBB`, the form designers hand over.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Components are clamped so a bad value can never produce an invalid colour.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.alpha = Self.unit(alpha)
    }

    /// WCAG 2 relative luminance. Alpha is ignored: palettes are opaque, and
    /// contrast against a translucent colour depends on what lies beneath it.
    public func relativeLuminance() -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, 1...21, independent of argument order.
    public static func contrastRatio(_ a: RGBA, _ b: RGBA) -> Double {
        let first = a.relativeLuminance()
        let second = b.relativeLuminance()
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// HSL hue in degrees, 0..<360 (0 for greys). Lets tests check that status
    /// colours differ in hue, not only in brightness, for colour-blind safety.
    public var hueDegrees: Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }
        let hue: Double
        if maximum == red {
            hue = (green - blue) / delta
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        let degrees = hue * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Whether the app follows macOS or forces one appearance. Only the adaptive
/// theme changes with appearance; fixed themes always look the same.
public enum AppearancePreference: String, Codable, Sendable, CaseIterable {
    case system
    case dark
    case light

    /// The appearance to render, given what macOS currently reports.
    public func resolvesToDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: systemIsDark
        case .dark: true
        case .light: false
        }
    }
}

public enum ThemeID: String, Codable, Sendable, CaseIterable, Identifiable {
    case midnight
    case graphite
    case obsidian
    case warmAmber
    case arctic
    case systemAdaptive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .obsidian: "Obsidian"
        case .warmAmber: "Warm Amber"
        case .arctic: "Arctic"
        case .systemAdaptive: "Match System"
        }
    }

    /// The accent that suits this theme when the user has not picked one, so
    /// Warm Amber reads as amber without overriding an explicit choice.
    public var suggestedAccent: AccentChoice {
        self == .warmAmber ? .amber : .claude
    }
}

public enum AccentChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Warm terracotta, Claude's own colour. The default.
    case claude
    case amber
    case coral
    case violet
    case teal
    case blue
    case graphite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .amber: "Amber"
        case .coral: "Coral"
        case .violet: "Violet"
        case .teal: "Teal"
        case .blue: "Blue"
        case .graphite: "Graphite"
        }
    }

    /// The accent tuned for dark palettes, where the notch lives.
    public var color: RGBA {
        switch self {
        case .claude: RGBA(0xD97757)
        case .amber: RGBA(0xE0A23E)
        case .coral: RGBA(0xF07F6E)
        case .violet: RGBA(0x9B86F0)
        case .teal: RGBA(0x2FB5A5)
        case .blue: RGBA(0x4C8EF5)
        case .graphite: RGBA(0x9A9AA0)
        }
    }

    /// The accent for a given palette. Light palettes get a deeper shade of the
    /// same hue, because the dark-tuned accents fall below 3:1 on near-white.
    public func color(isDark: Bool) -> RGBA {
        guard !isDark else { return color }
        switch self {
        case .claude: return RGBA(0xB4532F)
        case .amber: return RGBA(0x9A6400)
        case .coral: return RGBA(0xBF4A3A)
        case .violet: return RGBA(0x6E55C8)
        case .teal: return RGBA(0x137A6F)
        case .blue: return RGBA(0x2466CC)
        case .graphite: return RGBA(0x5E5E66)
        }
    }
}

/// Every colour a view needs, resolved for one theme and appearance.
public struct ThemePalette: Equatable, Sendable {
    public let background: RGBA
    public let surface: RGBA
    public let raised: RGBA
    public let hairline: RGBA
    public let textPrimary: RGBA
    public let textSecondary: RGBA
    public let textTertiary: RGBA

    /// Claude is running tools or thinking.
    public let working: RGBA
    /// Claude asked a question and waits for an answer.
    public let waiting: RGBA
    public let success: RGBA
    public let failure: RGBA
    /// Claude is blocked on a permission decision.
    public let permission: RGBA
    public let warning: RGBA

    public let isDark: Bool

    public init(
        background: RGBA,
        surface: RGBA,
        raised: RGBA,
        hairline: RGBA,
        textPrimary: RGBA,
        textSecondary: RGBA,
        textTertiary: RGBA,
        working: RGBA,
        waiting: RGBA,
        success: RGBA,
        failure: RGBA,
        permission: RGBA,
        warning: RGBA,
        isDark: Bool
    ) {
        self.background = background
        self.surface = surface
        self.raised = raised
        self.hairline = hairline
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.working = working
        self.waiting = waiting
        self.success = success
        self.failure = failure
        self.permission = permission
        self.warning = warning
        self.isDark = isDark
    }

    /// The six status colours in a fixed order, for checks and legends.
    public var semanticColors: [RGBA] {
        [working, waiting, success, failure, permission, warning]
    }
}

/// The built-in palettes.
///
/// Status hues stay the same across themes (blue working, violet waiting,
/// green success, red failure, orange permission, yellow warning) so meaning
/// survives a theme switch; only lightness shifts to keep contrast. Every
/// palette meets WCAG AAA for primary text (7:1), AA for secondary text
/// (4.5:1) and 3:1 for status colours against its background; tests enforce it.
public enum ThemeLibrary {
    public static func palette(for theme: ThemeID, systemIsDark: Bool) -> ThemePalette {
        switch theme {
        case .midnight: midnight
        case .graphite: graphite
        case .obsidian: obsidian
        case .warmAmber: warmAmber
        case .arctic: arctic
        // Graphite is the neutral grey closest to macOS dark mode, and Arctic is
        // the light palette, so "Match System" looks native either way.
        case .systemAdaptive: systemIsDark ? graphite : arctic
        }
    }

    /// Resolves a theme with the user's appearance override applied.
    public static func palette(
        for theme: ThemeID,
        appearance: AppearancePreference,
        systemIsDark: Bool
    ) -> ThemePalette {
        palette(for: theme, systemIsDark: appearance.resolvesToDark(systemIsDark: systemIsDark))
    }

    /// Deep blue-black: the default, calm beside the black notch.
    static let midnight = ThemePalette(
        background: RGBA(0x0B0F1A),
        surface: RGBA(0x121826),
        raised: RGBA(0x1A2233),
        hairline: RGBA(0x2A3447),
        textPrimary: RGBA(0xE8ECF4),
        textSecondary: RGBA(0xA3ADC2),
        textTertiary: RGBA(0x737D94),
        working: RGBA(0x6CA8F0),
        waiting: RGBA(0xA99BEF),
        success: RGBA(0x6CC28A),
        failure: RGBA(0xEE7470),
        permission: RGBA(0xF09A55),
        warning: RGBA(0xE3CF62),
        isDark: true
    )

    /// Neutral dark grey with no colour cast.
    static let graphite = ThemePalette(
        background: RGBA(0x1C1C1E),
        surface: RGBA(0x242426),
        raised: RGBA(0x2C2C2E),
        hairline: RGBA(0x3A3A3C),
        textPrimary: RGBA(0xF2F2F2),
        textSecondary: RGBA(0xAEAEB2),
        textTertiary: RGBA(0x85858A),
        working: RGBA(0x6CA8F0),
        waiting: RGBA(0xA99BEF),
        success: RGBA(0x6CC28A),
        failure: RGBA(0xEE7470),
        permission: RGBA(0xF09A55),
        warning: RGBA(0xE3CF62),
        isDark: true
    )

    /// True black with the highest contrast, blending into the hardware notch.
    static let obsidian = ThemePalette(
        background: RGBA(0x000000),
        surface: RGBA(0x0C0C0C),
        raised: RGBA(0x161616),
        hairline: RGBA(0x2A2A2A),
        textPrimary: RGBA(0xFFFFFF),
        textSecondary: RGBA(0xBDBDBD),
        textTertiary: RGBA(0x8A8A8A),
        working: RGBA(0x7AB4FF),
        waiting: RGBA(0xB6A9FF),
        success: RGBA(0x74D196),
        failure: RGBA(0xFF7F7A),
        permission: RGBA(0xFFA866),
        warning: RGBA(0xF0DA70),
        isDark: true
    )

    /// Warm brown-black with amber-tinted surfaces and text.
    static let warmAmber = ThemePalette(
        background: RGBA(0x17110B),
        surface: RGBA(0x201810),
        raised: RGBA(0x2B2117),
        hairline: RGBA(0x3D2F21),
        textPrimary: RGBA(0xF6ECDF),
        textSecondary: RGBA(0xC7B59D),
        textTertiary: RGBA(0x95836C),
        working: RGBA(0x74A9E0),
        waiting: RGBA(0xB3A0E0),
        success: RGBA(0x8CC489),
        failure: RGBA(0xEC706A),
        permission: RGBA(0xF0984E),
        warning: RGBA(0xE6CF63),
        isDark: true
    )

    /// Light, cool white and blue-grey. Status colours are deeper shades so
    /// they still reach 3:1 on a near-white background.
    static let arctic = ThemePalette(
        background: RGBA(0xF4F7FA),
        surface: RGBA(0xFFFFFF),
        raised: RGBA(0xE8EDF3),
        hairline: RGBA(0xD2DAE4),
        textPrimary: RGBA(0x101824),
        textSecondary: RGBA(0x445063),
        textTertiary: RGBA(0x6A7587),
        working: RGBA(0x1F6CC9),
        waiting: RGBA(0x6E4FC2),
        success: RGBA(0x1D7F48),
        failure: RGBA(0xC5373A),
        permission: RGBA(0xB8540F),
        warning: RGBA(0x806E00),
        isDark: false
    )
}
