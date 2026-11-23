import CoreGraphics
import Foundation

/// Which display the notch lives on. The window coordinator asks once,
/// remembers the answer, and uses that one screen for both the panel's frame
/// and pointer hit-testing, so the two can never disagree.
public enum NotchScreenChoice {
    /// What the rule needs to know about one display.
    public struct Screen: Equatable, Sendable {
        /// The display's frame in global screen coordinates.
        public let frame: CGRect
        /// The display has a camera housing (a top safe-area inset).
        public let hasNotch: Bool

        public init(frame: CGRect, hasNotch: Bool) {
            self.frame = frame
            self.hasNotch = hasNotch
        }
    }

    /// The index of the display to use, or nil when there is none.
    /// `screens` is in AppKit's order, so the first is the primary display
    /// (the one System Settings calls the main display). The primary display
    /// is used rather than the one with keyboard focus because focus moves
    /// with every click, and the notch must not move with it.
    public static func index(
        preference: DisplayPreference,
        screens: [Screen],
        pointer: CGPoint?
    ) -> Int? {
        guard !screens.isEmpty else { return nil }
        switch preference {
        case .notchedDisplay:
            return notchedOrPrimary(screens)
        case .mainDisplay:
            return 0
        case .displayWithPointer:
            guard let pointer,
                  let index = screens.firstIndex(where: { contains($0.frame, pointer) }) else {
                // Between displays or unknown: the default rule.
                return notchedOrPrimary(screens)
            }
            return index
        }
    }

    private static func notchedOrPrimary(_ screens: [Screen]) -> Int {
        screens.firstIndex(where: \.hasNotch) ?? 0
    }

    /// A pointer pushed against a display's top or right edge reports the
    /// edge itself, which `CGRect.contains` leaves out.
    private static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }
}
