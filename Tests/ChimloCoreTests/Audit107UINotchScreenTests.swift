import ChimloCore
import CoreGraphics
import Foundation
import Testing

/// "Show the notch on" must pick a display, and the pick must not depend on
/// which window has keyboard focus: on a Mac without a notch and with two
/// displays the notch used to be drawn on one and hit-tested on the other.
@Suite("Audit 1.0.7 UI: which display the notch is on")
struct Audit107UINotchScreenTests {
    private let builtIn = NotchScreenChoice.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true)
    private let plain = NotchScreenChoice.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), hasNotch: false)
    private let external = NotchScreenChoice.Screen(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), hasNotch: false)

    @Test("By default a Mac with a notch keeps the notch on the notched display, wherever it is listed")
    func defaultPrefersTheNotch() {
        let pointerOnExternal = CGPoint(x: 2000, y: 500)
        #expect(NotchScreenChoice.index(preference: .notchedDisplay, screens: [builtIn, external], pointer: pointerOnExternal) == 0)
        #expect(NotchScreenChoice.index(preference: .notchedDisplay, screens: [external, builtIn], pointer: pointerOnExternal) == 1)
        #expect(NotchScreenChoice.index(preference: .notchedDisplay, screens: [builtIn], pointer: nil) == 0)
    }

    @Test("Without a notch the default is the primary display, whatever the pointer or focus is doing")
    func defaultWithoutANotchIsThePrimaryDisplay() {
        for pointer in [CGPoint(x: 100, y: 100), CGPoint(x: 3000, y: 700)] {
            #expect(NotchScreenChoice.index(preference: .notchedDisplay, screens: [plain, external], pointer: pointer) == 0)
        }
        #expect(NotchScreenChoice.index(preference: .notchedDisplay, screens: [plain, external], pointer: nil) == 0)
    }

    @Test("The main display is the primary one, even when another display has a notch")
    func mainDisplayIsThePrimary() {
        #expect(NotchScreenChoice.index(preference: .mainDisplay, screens: [external, builtIn], pointer: CGPoint(x: 10, y: 10)) == 0)
        #expect(NotchScreenChoice.index(preference: .mainDisplay, screens: [builtIn, external], pointer: CGPoint(x: 3000, y: 10)) == 0)
    }

    @Test("The display with the pointer follows the pointer, edges included")
    func followsThePointer() {
        let screens = [builtIn, external]
        #expect(NotchScreenChoice.index(preference: .displayWithPointer, screens: screens, pointer: CGPoint(x: 700, y: 400)) == 0)
        #expect(NotchScreenChoice.index(preference: .displayWithPointer, screens: screens, pointer: CGPoint(x: 3000, y: 400)) == 1)
        // Pushed against the top of the external display, y is its maxY.
        #expect(NotchScreenChoice.index(preference: .displayWithPointer, screens: screens, pointer: CGPoint(x: 3000, y: 1440)) == 1)
        // Pushed against the far right edge, x is its maxX.
        #expect(NotchScreenChoice.index(preference: .displayWithPointer, screens: screens, pointer: CGPoint(x: 4072, y: 10)) == 1)
    }

    @Test("A pointer on no display, or unknown, falls back to the default rule")
    func pointerOffScreenUsesTheDefault() {
        #expect(NotchScreenChoice.index(preference: .displayWithPointer, screens: [external, builtIn], pointer: CGPoint(x: -500, y: -500)) == 1)
        #expect(NotchScreenChoice.index(preference: .displayWithPointer, screens: [plain, external], pointer: nil) == 0)
    }

    @Test("No display, no notch")
    func noScreens() {
        for preference in DisplayPreference.allCases {
            #expect(NotchScreenChoice.index(preference: preference, screens: [], pointer: CGPoint(x: 1, y: 1)) == nil)
        }
    }

    @Test("Every preference names a display that exists")
    func indexIsAlwaysInRange() {
        let layouts = [[builtIn], [plain], [builtIn, external], [external, builtIn], [plain, external]]
        let pointers: [CGPoint?] = [nil, CGPoint(x: 5, y: 5), CGPoint(x: 3000, y: 100), CGPoint(x: -1, y: 99_999)]
        for preference in DisplayPreference.allCases {
            for screens in layouts {
                for pointer in pointers {
                    let index = NotchScreenChoice.index(preference: preference, screens: screens, pointer: pointer)
                    #expect(index.map(screens.indices.contains) == true)
                }
            }
        }
    }
}
