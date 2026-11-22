import Foundation
import Testing
@testable import ChimloCore

@Suite("Themes")
struct ThemeTests {
    /// Every palette a user can end up with: each theme, and both system modes.
    private var allPalettes: [(String, ThemePalette)] {
        ThemeID.allCases.flatMap { theme in
            [false, true].map { dark in
                ("\(theme.rawValue)/\(dark ? "dark" : "light")", ThemeLibrary.palette(for: theme, systemIsDark: dark))
            }
        }
    }

    @Test("Hex colours parse into unit components")
    func hexParsing() {
        let colour = RGBA(0xFF8000, alpha: 0.5)
        #expect(colour.red == 1)
        #expect(abs(colour.green - 128.0 / 255) < 0.0001)
        #expect(colour.blue == 0)
        #expect(colour.alpha == 0.5)
        #expect(RGBA(red: 2, green: -1, blue: .nan, alpha: 3) == RGBA(red: 1, green: 0, blue: 0, alpha: 1))
    }

    @Test("Contrast ratio follows WCAG and ignores argument order")
    func contrastRatio() {
        let black = RGBA(0x000000)
        let white = RGBA(0xFFFFFF)
        #expect(abs(RGBA.contrastRatio(black, white) - 21) < 0.001)
        #expect(RGBA.contrastRatio(white, black) == RGBA.contrastRatio(black, white))
        #expect(RGBA.contrastRatio(white, white) == 1)
        #expect(abs(white.relativeLuminance() - 1) < 0.0001)
    }

    @Test("Text in every palette meets 7:1 primary and 4.5:1 secondary contrast")
    func textContrast() {
        for (name, palette) in allPalettes {
            let primary = RGBA.contrastRatio(palette.textPrimary, palette.background)
            let secondary = RGBA.contrastRatio(palette.textSecondary, palette.background)
            #expect(primary >= 7, "\(name) primary \(primary)")
            #expect(secondary >= 4.5, "\(name) secondary \(secondary)")
            // Secondary text also sits on cards, so check the surfaces too.
            #expect(RGBA.contrastRatio(palette.textSecondary, palette.surface) >= 4.5, "\(name) on surface")
            #expect(RGBA.contrastRatio(palette.textSecondary, palette.raised) >= 4.5, "\(name) on raised")
        }
    }

    @Test("Status colours reach 3:1 and are distinguishable from each other")
    func semanticColours() {
        for (name, palette) in allPalettes {
            let colours = palette.semanticColors
            #expect(colours.count == 6)
            for colour in colours {
                #expect(RGBA.contrastRatio(colour, palette.background) >= 3, "\(name) \(colour)")
            }
            for first in colours.indices {
                for second in colours.indices where second > first {
                    let a = colours[first]
                    let b = colours[second]
                    let rawHue = abs(a.hueDegrees - b.hueDegrees)
                    let hueGap = min(rawHue, 360 - rawHue)
                    let contrast = RGBA.contrastRatio(a, b)
                    #expect(hueGap >= 20 || contrast >= 1.5, "\(name) \(first) vs \(second): hue \(hueGap), contrast \(contrast)")
                }
            }
        }
    }

    @Test("Match System follows macOS; fixed themes ignore it")
    func adaptiveTheme() {
        #expect(ThemeLibrary.palette(for: .systemAdaptive, systemIsDark: true).isDark)
        #expect(!ThemeLibrary.palette(for: .systemAdaptive, systemIsDark: false).isDark)
        #expect(ThemeLibrary.palette(for: .systemAdaptive, systemIsDark: false) == ThemeLibrary.palette(for: .arctic, systemIsDark: true))
        for theme in ThemeID.allCases where theme != .systemAdaptive {
            #expect(ThemeLibrary.palette(for: theme, systemIsDark: true) == ThemeLibrary.palette(for: theme, systemIsDark: false))
        }
        #expect(!ThemeLibrary.palette(for: .arctic, systemIsDark: true).isDark)
        #expect(ThemeLibrary.palette(for: .obsidian, systemIsDark: false).background == RGBA(0x000000))
    }

    @Test("The window's light or dark always matches the theme's backgrounds, in either macOS mode")
    func windowAppearanceMatchesPalette() {
        // Native controls draw text for the window's appearance; if it ever
        // disagreed with the palette, text would vanish into the background.
        for theme in ThemeID.allCases {
            for systemIsDark in [true, false] {
                let palette = ThemeLibrary.palette(for: theme, systemIsDark: systemIsDark)
                let windowIsDark = ThemeLibrary.windowAppearanceIsDark(for: theme) ?? systemIsDark
                #expect(windowIsDark == palette.isDark, "\(theme) with macOS \(systemIsDark ? "dark" : "light")")
            }
        }
        #expect(ThemeLibrary.windowAppearanceIsDark(for: .arctic) == false)
        #expect(ThemeLibrary.windowAppearanceIsDark(for: .midnight) == true)
        #expect(ThemeLibrary.windowAppearanceIsDark(for: .systemAdaptive) == nil, "Match System follows macOS")
    }

    @Test("Themes are genuinely different palettes")
    func themesDiffer() {
        let fixed = ThemeID.allCases.filter { $0 != .systemAdaptive }
        let backgrounds = Set(fixed.map { ThemeLibrary.palette(for: $0, systemIsDark: true).background })
        #expect(backgrounds.count == fixed.count)
        #expect(Set(ThemeID.allCases.map(\.displayName)).count == ThemeID.allCases.count)
    }

    @Test("Accents are distinct and readable on dark and light palettes")
    func accents() {
        #expect(Set(AccentChoice.allCases.map(\.color)).count == AccentChoice.allCases.count)
        #expect(AccentChoice.claude.color == RGBA(0xD97757))
        let light = ThemeLibrary.palette(for: .arctic, systemIsDark: false)
        for accent in AccentChoice.allCases {
            #expect(RGBA.contrastRatio(accent.color(isDark: false), light.background) >= 3, "\(accent)")
            #expect(accent.color(isDark: true) == accent.color)
            for theme in ThemeID.allCases where ThemeLibrary.palette(for: theme, systemIsDark: true).isDark {
                let palette = ThemeLibrary.palette(for: theme, systemIsDark: true)
                #expect(RGBA.contrastRatio(accent.color, palette.background) >= 3, "\(accent) on \(theme)")
            }
        }
        #expect(ThemeID.warmAmber.suggestedAccent == .amber)
        #expect(ThemeID.midnight.suggestedAccent == .claude)
    }
}

@Suite("Notch layouts")
struct NotchLayoutTests {
    private func differingFields(_ a: NotchLayoutSpec, _ b: NotchLayoutSpec) -> Int {
        [
            a.showsAvatar != b.showsAvatar,
            a.showsActivityLabel != b.showsActivityLabel,
            a.showsContextIndicator != b.showsContextIndicator,
            a.showsAgentIndicator != b.showsAgentIndicator,
            a.showsAttentionSignal != b.showsAttentionSignal,
            a.compactWingWidthScale != b.compactWingWidthScale,
            a.expandedShowsUsage != b.expandedShowsUsage,
            a.expandedShowsAgents != b.expandedShowsAgents,
            a.expandedRowDensity != b.expandedRowDensity,
            a.expandsOnHover != b.expandsOnHover,
            a.animationScale != b.animationScale,
        ].filter { $0 }.count
    }

    @Test("Every layout is a distinct spec within its ranges")
    func distinctSpecs() {
        let specs = NotchLayout.allCases.map(\.spec)
        for first in specs.indices {
            #expect(NotchLayoutSpec.wingWidthRange.contains(specs[first].compactWingWidthScale))
            #expect((0...1).contains(specs[first].animationScale))
            #expect(specs[first].showsAttentionSignal, "every layout must signal attention")
            for second in specs.indices where second > first {
                #expect(differingFields(specs[first], specs[second]) >= 2, "\(first) vs \(second)")
            }
        }
        #expect(Set(NotchLayout.allCases.map(\.displayName)).count == NotchLayout.allCases.count)
        #expect(NotchLayout.allCases.allSatisfy { !$0.summary.isEmpty })
    }

    @Test("Minimal and expanded differ in at least four ways")
    func minimalVersusExpanded() {
        let minimal = NotchLayout.minimal.spec
        let expanded = NotchLayout.expanded.spec
        #expect(differingFields(minimal, expanded) >= 4)
        #expect(minimal.showsAvatar && minimal.showsAttentionSignal)
        #expect(!minimal.showsActivityLabel && !minimal.showsContextIndicator && !minimal.showsAgentIndicator)
        #expect(minimal.compactWingWidthScale < NotchLayout.classic.spec.compactWingWidthScale)
        #expect(expanded.showsContextIndicator && expanded.showsAgentIndicator && expanded.showsActivityLabel)
        #expect(expanded.compactWingWidthScale > NotchLayout.classic.spec.compactWingWidthScale)
        #expect(expanded.expandedShowsUsage && expanded.expandedShowsAgents)
    }

    @Test("Classic, focus and agent view match their descriptions")
    func namedLayouts() {
        let classic = NotchLayout.classic.spec
        #expect(classic.showsAvatar && classic.showsActivityLabel && classic.showsAttentionSignal)
        #expect(classic.compactWingWidthScale == 1)

        let focus = NotchLayout.focus.spec
        #expect(!focus.expandsOnHover)
        #expect(!focus.showsActivityLabel && !focus.showsAvatar && !focus.showsContextIndicator && !focus.showsAgentIndicator)
        #expect(focus.showsAttentionSignal)
        #expect(focus.animationScale == 0.2)
        #expect(NotchLayout.allCases.filter { !$0.spec.expandsOnHover } == [.focus])

        let agents = NotchLayout.agentView.spec
        #expect(agents.showsAgentIndicator && agents.expandedShowsAgents)
        #expect(agents.expandedRowDensity == .compact)
    }

    @Test("Animation intensity scales")
    func animationIntensity() {
        #expect(AnimationIntensity.full.scale == 1)
        #expect(AnimationIntensity.reduced.scale == 0.5)
        #expect(AnimationIntensity.minimal.scale == 0.15)
    }

    @Test("Resolved layout applies Focus, agents, density and animation settings")
    func resolvedSpec() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var settings = OverheadSettings()
        settings.layout = .expanded
        #expect(settings.resolvedLayoutSpec(at: now) == NotchLayout.expanded.spec)

        settings.animationIntensity = .reduced
        settings.showAgents = false
        settings.density = .compact
        let calmer = settings.resolvedLayoutSpec(at: now)
        #expect(calmer.animationScale == 0.5)
        #expect(!calmer.showsAgentIndicator && !calmer.expandedShowsAgents)
        #expect(calmer.expandedRowDensity == .compact)
        #expect(calmer.showsActivityLabel)

        settings.focus.isOn = true
        let focused = settings.resolvedLayoutSpec(at: now)
        #expect(!focused.showsActivityLabel)
        #expect(focused.animationScale <= AnimationIntensity.minimal.scale)
        #expect(focused.expandsOnHover == NotchLayout.expanded.spec.expandsOnHover)
    }

    @Test("The closed notch's activity line follows its setting, the layout and Focus")
    func closedNotchActivity() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var settings = OverheadSettings()
        #expect(settings.showClosedNotchActivity)
        #expect(settings.showsClosedNotchActivity(at: now))

        settings.showClosedNotchActivity = false
        #expect(!settings.showsClosedNotchActivity(at: now))
        #expect(settings.resolvedLayoutSpec(at: now).showsActivityLabel, "the wing glyph stays")

        settings.showClosedNotchActivity = true
        for layout in NotchLayout.allCases {
            settings.layout = layout
            #expect(settings.showsClosedNotchActivity(at: now) == layout.spec.showsActivityLabel, "\(layout)")
        }
        #expect(!NotchLayout.minimal.spec.showsActivityLabel && !NotchLayout.focus.spec.showsActivityLabel)

        settings.layout = .classic
        settings.focus.isOn = true
        settings.focus.hideActivityLabels = true
        #expect(!settings.showsClosedNotchActivity(at: now))
        settings.focus.hideActivityLabels = false
        #expect(settings.showsClosedNotchActivity(at: now))
    }
}

@Suite("Shortcuts")
struct ShortcutTests {
    @Test("Defaults use the documented key codes with Control-Option")
    func defaultBindings() {
        let expected: [ShortcutAction: UInt16] = [
            .togglePanel: 31, .showSessions: 1, .nextSession: 30, .previousSession: 33,
            .focusTerminal: 17, .openHistory: 4, .toggleFocusMode: 3, .openSettings: 43,
            .toggleGitHubMode: 5,
        ]
        #expect(ShortcutDefaults.bindings.count == ShortcutAction.allCases.count)
        for action in ShortcutAction.allCases {
            #expect(ShortcutDefaults.bindings[action]?.keyCode == expected[action], "\(action)")
            #expect(ShortcutDefaults.bindings[action]?.modifiers == [.control, .option], "\(action)")
        }
    }

    @Test("Defaults conflict with nothing, each other or macOS")
    func defaultsHaveNoConflicts() {
        let bindings = ShortcutDefaults.bindings
        for (action, combo) in bindings {
            #expect(ShortcutValidator.conflicts(for: combo, action: action, in: bindings).isEmpty, "\(action)")
        }
        #expect(Set(bindings.values).count == bindings.count)
        let reserved = Set(ShortcutValidator.reservedShortcuts.map(\.combo))
        #expect(reserved.isDisjoint(with: Set(bindings.values)))
    }

    @Test("Validator reports duplicates, system reservations and missing modifiers")
    func validator() {
        let bindings = ShortcutDefaults.bindings
        let toggle = ShortcutDefaults.bindings[.togglePanel] ?? KeyCombo(keyCode: 31, modifiers: [.control, .option])
        #expect(ShortcutValidator.conflicts(for: toggle, action: .openHistory, in: bindings) == [.duplicate(.togglePanel)])
        #expect(ShortcutValidator.conflicts(for: toggle, action: .togglePanel, in: bindings).isEmpty)

        let spotlight = KeyCombo(keyCode: VirtualKey.space, modifiers: .command)
        #expect(ShortcutValidator.conflicts(for: spotlight, action: .togglePanel, in: bindings) == [.reservedBySystem("Spotlight")])

        let screenshot = KeyCombo(keyCode: 21, modifiers: [.command, .shift])
        #expect(ShortcutValidator.conflicts(for: screenshot, action: .togglePanel, in: [:]) == [.reservedBySystem("Screenshot of selection")])
        let missionControl = KeyCombo(keyCode: 126, modifiers: .control)
        #expect(ShortcutValidator.conflicts(for: missionControl, action: .togglePanel, in: [:]).count == 1)
        let forceQuit = KeyCombo(keyCode: 53, modifiers: [.command, .option])
        #expect(ShortcutValidator.conflicts(for: forceQuit, action: .togglePanel, in: [:]) == [.reservedBySystem("Force Quit")])

        // Shift alone is not enough for a global shortcut.
        #expect(ShortcutValidator.conflicts(for: KeyCombo(keyCode: 31, modifiers: []), action: .togglePanel, in: [:]) == [.needsModifier])
        #expect(ShortcutValidator.conflicts(for: KeyCombo(keyCode: 31, modifiers: .shift), action: .togglePanel, in: [:]) == [.needsModifier])
        #expect(ShortcutValidator.conflicts(for: KeyCombo(keyCode: 31, modifiers: .option), action: .togglePanel, in: [:]).isEmpty)

        // A bare key that two actions share reports both problems, in order.
        let bare = KeyCombo(keyCode: 4, modifiers: [])
        let shared: [ShortcutAction: KeyCombo] = [.openHistory: bare, .showSessions: bare]
        #expect(ShortcutValidator.conflicts(for: bare, action: .togglePanel, in: shared) == [.needsModifier, .duplicate(.showSessions), .duplicate(.openHistory)])
    }

    @Test("Display strings use macOS modifier order and key symbols")
    func displayStrings() {
        #expect(ShortcutDefaults.bindings[.togglePanel]?.displayString == "⌃⌥O")
        #expect(ShortcutDefaults.bindings[.nextSession]?.displayString == "⌃⌥]")
        #expect(ShortcutDefaults.bindings[.openSettings]?.displayString == "⌃⌥,")
        #expect(KeyCombo(keyCode: 1, modifiers: [.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘S")
        #expect(KeyCombo(keyCode: 49, modifiers: .command).displayString == "⌘Space")
        #expect(KeyCombo(keyCode: 126, modifiers: .control).displayString == "⌃↑")
        #expect(KeyCombo(keyCode: 122, modifiers: .option).displayString == "⌥F1")
        #expect(KeyCombo(keyCode: 200, modifiers: .command).displayString == "⌘Key 200")
    }

    @Test("Modifiers convert to Carbon hot-key flags and round-trip through JSON")
    func modifiers() throws {
        #expect(KeyModifiers([.control, .option]).carbonFlags == 0x1800)
        #expect(KeyModifiers([.command, .shift]).carbonFlags == 0x0300)
        let combo = KeyCombo(keyCode: 17, modifiers: [.control, .option, .shift])
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
        #expect(decoded == combo)
    }

    @Test("Every action has a distinct display name")
    func actionNames() {
        #expect(Set(ShortcutAction.allCases.map(\.displayName)).count == ShortcutAction.allCases.count)
    }
}
