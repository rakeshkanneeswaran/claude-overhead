import ChimloCore
import SwiftUI

/// Claude Code's mark in the notch: the orange spark its terminal greets you
/// with (✻), drawn as a vector so it stays crisp at every size the notch uses.
/// It is a generic eight-spoke asterisk in Claude's colour, not Anthropic's
/// logo artwork.
///
/// One symbol everywhere; the mood shows as motion, never as a different
/// picture: it turns slowly while Claude works, breathes while Claude waits on
/// the owner, and rests otherwise. With Reduce Motion it always rests.
struct ClaudeCodeMark: View {
    let mood: AvatarMood
    var size: CGFloat = 32
    var reduceMotion = false

    /// Claude's terracotta, the colour of Claude Code's own spark.
    static let claudeOrange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    var body: some View {
        Group {
            if reduceMotion || !isAnimated {
                mark(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 24)) { context in
                    mark(at: context.date.timeIntervalSinceReferenceDate)
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

    private func mark(at time: TimeInterval) -> some View {
        let turn: Angle = mood == .working ? .degrees((time * 45).truncatingRemainder(dividingBy: 360)) : .zero
        let breath: CGFloat = (mood == .waiting || mood == .question) && time != 0
            ? 0.88 + 0.12 * (0.5 + 0.5 * sin(time * 3.4))
            : 1
        return ClaudeSparkShape()
            .fill(Self.claudeOrange)
            .opacity(mood == .idle ? 0.78 : 1)
            .padding(size * 0.06)
            .scaleEffect(breath)
            .rotationEffect(turn)
    }
}

/// Eight teardrop spokes around a small hub: narrow at the centre, round at
/// the tip, like the ✻ Claude Code prints.
struct ClaudeSparkShape: Shape {
    var spokes = 8

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let hub = radius * 0.14
        let half = radius * 0.2
        var path = Path()
        for index in 0..<spokes {
            var spoke = Path()
            let base = CGPoint(x: centre.x, y: centre.y - hub)
            let tip = CGPoint(x: centre.x, y: centre.y - radius)
            spoke.move(to: base)
            spoke.addCurve(
                to: tip,
                control1: CGPoint(x: centre.x - half * 0.5, y: centre.y - radius * 0.45),
                control2: CGPoint(x: centre.x - half * 1.1, y: tip.y + half * 0.05)
            )
            spoke.addCurve(
                to: base,
                control1: CGPoint(x: centre.x + half * 1.1, y: tip.y + half * 0.05),
                control2: CGPoint(x: centre.x + half * 0.5, y: centre.y - radius * 0.45)
            )
            let angle = CGFloat(index) * (.pi * 2 / CGFloat(spokes))
            let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: angle)
                .translatedBy(x: -centre.x, y: -centre.y)
            path.addPath(spoke, transform: transform)
        }
        path.addEllipse(in: CGRect(x: centre.x - hub * 1.5, y: centre.y - hub * 1.5, width: hub * 3, height: hub * 3))
        return path
    }
}
