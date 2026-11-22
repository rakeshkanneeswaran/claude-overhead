import ChimloCore
import SwiftUI

extension RGBA {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// A theme resolved for the current appearance, with SwiftUI colours. Every
/// companion surface reads colours from here, so switching theme is one change.
struct OverheadPalette: Equatable {
    let theme: ThemePalette
    let accent: RGBA

    var backgroundColor: Color { theme.background.color }
    var surfaceColor: Color { theme.surface.color }
    var raisedColor: Color { theme.raised.color }
    var hairlineColor: Color { theme.hairline.color }
    var textPrimary: Color { theme.textPrimary.color }
    var textSecondary: Color { theme.textSecondary.color }
    var textTertiary: Color { theme.textTertiary.color }
    var accentColor: Color { accent.color }
    var working: Color { theme.working.color }
    var waiting: Color { theme.waiting.color }
    var success: Color { theme.success.color }
    var failure: Color { theme.failure.color }
    var permission: Color { theme.permission.color }
    var warning: Color { theme.warning.color }
    var isDark: Bool { theme.isDark }

    static let fallback = OverheadPalette(
        theme: ThemeLibrary.palette(for: .midnight, systemIsDark: true),
        accent: AccentChoice.claude.color(isDark: true)
    )
}

private struct OverheadPaletteKey: EnvironmentKey {
    static let defaultValue = OverheadPalette.fallback
}

extension EnvironmentValues {
    var overheadPalette: OverheadPalette {
        get { self[OverheadPaletteKey.self] }
        set { self[OverheadPaletteKey.self] = newValue }
    }
}

/// The single owner of the owner's preferences. Changes save immediately and
/// fan out through `onChange`, so a toggle takes effect at once and nothing
/// keeps a private copy of a preference.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: OverheadSettings {
        didSet {
            guard settings != oldValue else { return }
            let normalized = settings.normalized()
            if normalized != settings {
                settings = normalized
                return
            }
            store.save(settings)
            onChange?(oldValue, settings)
        }
    }

    /// Called after every change with the previous and new settings.
    var onChange: ((OverheadSettings, OverheadSettings) -> Void)?

    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        settings = store.load()
    }

    func palette(systemIsDark: Bool) -> OverheadPalette {
        // The theme alone decides light or dark (see windowAppearanceIsDark).
        let theme = ThemeLibrary.palette(for: settings.theme, systemIsDark: systemIsDark)
        return OverheadPalette(theme: theme, accent: settings.accent.color(isDark: theme.isDark))
    }

    /// The layout as it applies right now, with Focus and animation
    /// preferences folded in.
    var layoutSpec: NotchLayoutSpec { settings.resolvedLayoutSpec(at: .now, calendar: .current) }

    func binding<Value>(_ keyPath: WritableKeyPath<OverheadSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0 }
        )
    }
}
