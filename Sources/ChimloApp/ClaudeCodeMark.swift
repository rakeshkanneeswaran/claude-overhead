import ChimloCore
import SwiftUI

/// Claude Code's pixel mascot, the orange creature from its welcome screen,
/// which marks Claude Code sessions in the notch.
///
/// Drawn as true pixel art: each sprite pixel is snapped to whole half-points,
/// so it lands on the display's pixel grid and stays sharp at every size.
/// One character everywhere; the mood shows as motion, never as a different
/// picture: it bobs while Claude works, raises its arms while Claude waits on
/// the owner, and stands still otherwise. With Reduce Motion it stands still.
struct ClaudeCodeMark: View {
    let mood: AvatarMood
    var size: CGFloat = 32
    var reduceMotion = false

    /// Claude's terracotta.
    static let claudeOrange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    var body: some View {
        Group {
            if reduceMotion || !isAnimated {
                sprite(frame: 0)
            } else {
                TimelineView(.periodic(from: .now, by: interval)) { timeline in
                    sprite(frame: Int(timeline.date.timeIntervalSinceReferenceDate / interval) & 1)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Code, \(mood.accessibilityDescription)")
    }

    private var isAnimated: Bool {
        mood == .working || mood == .waiting || mood == .question
    }

    private var interval: TimeInterval { mood == .working ? 0.34 : 0.5 }

    private func sprite(frame: Int) -> some View {
        let rows = ClaudeMascotSprite.rows(mood: mood, frame: frame)
        let bobs = mood == .working && frame == 1
        let color = Self.claudeOrange.opacity(mood == .idle ? 0.78 : 1)
        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvas in
            let columns = CGFloat(ClaudeMascotSprite.columns)
            let height = CGFloat(rows.count)
            // Whole half-points: on a Retina display every sprite pixel is a
            // whole number of screen pixels.
            let fit = min(canvas.width / columns, canvas.height / height)
            let unit = max(0.5, (fit * 2).rounded(.down) / 2)
            let width = unit * columns
            let tall = unit * height
            let originX = ((canvas.width - width)).rounded(.down) / 2
            let originY = ((canvas.height - tall)).rounded(.down) / 2 - (bobs ? unit : 0)
            var path = Path()
            for (row, line) in rows.enumerated() {
                for (column, cell) in line.enumerated() where cell == "#" {
                    path.addRect(CGRect(
                        x: originX + CGFloat(column) * unit,
                        y: originY + CGFloat(row) * unit,
                        width: unit,
                        height: unit
                    ))
                }
            }
            context.fill(path, with: .color(color))
        }
    }
}

/// The mascot as a 16 × 10 grid: a 12 × 8 body with two eye holes, arms two
/// rows tall at its sides, and four legs.
enum ClaudeMascotSprite {
    static let columns = 16

    static let standing = [
        "..############..",
        "..############..",
        "..##.######.##..",
        "..##.######.##..",
        "################",
        "################",
        "..############..",
        "..############..",
        "...#.#....#.#...",
        "...#.#....#.#...",
    ]

    /// Arms up, beside the eyes: "your turn".
    static let armsUp = [
        "..############..",
        "..############..",
        "####.######.####",
        "####.######.####",
        "..############..",
        "..############..",
        "..############..",
        "..############..",
        "...#.#....#.#...",
        "...#.#....#.#...",
    ]

    static func rows(mood: AvatarMood, frame: Int) -> [String] {
        switch mood {
        case .waiting, .question: frame == 1 ? armsUp : standing
        default: standing
        }
    }
}
