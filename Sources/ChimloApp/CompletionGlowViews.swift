import ChimloCore
import SwiftUI

/// A completion glow filling a shape: the closed notch, or a miniature of
/// it. Every layer fills the shape itself, so the glow follows each corner.
///
/// The view exists only while a glow shows. With the glow switched off it is
/// never created, so nothing is drawn or timed.
struct CompletionGlowFill<S: Shape>: View {
    let shape: S
    let theme: GlowTheme
    /// False holds the theme's still picture: Reduce Motion, Focus, or a
    /// swatch at rest.
    let flows: Bool
    /// How large the shape is beside the real notch, so a miniature's
    /// outline is as fine as the miniature.
    var scale: CGFloat = 1

    var body: some View {
        let moves = flows && theme.isAnimated
        // 60 fps is plenty for slow motion and halves the redraw cost on
        // ProMotion. Paused, the timeline draws once and stops.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moves)) { context in
            GlowFrame(
                shape: shape,
                layers: theme.layers(at: moves ? context.date.timeIntervalSinceReferenceDate : nil),
                scale: scale
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One moment of a theme: its layers, back to front.
struct GlowFrame<S: Shape>: View {
    let shape: S
    let layers: [GlowLayer]
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            ForEach(layers.indices, id: \.self) { index in
                layer(layers[index])
            }
        }
    }

    @ViewBuilder
    private func layer(_ layer: GlowLayer) -> some View {
        let stops = layer.stops.map { Gradient.Stop(color: $0.color.color, location: $0.location) }
        switch layer.form {
        case let .linear(startX, startY, endX, endY):
            shape
                .fill(LinearGradient(
                    stops: stops,
                    startPoint: UnitPoint(x: startX, y: startY),
                    endPoint: UnitPoint(x: endX, y: endY)
                ))
                .opacity(layer.opacity)
        case let .radial(centerX, centerY, radius):
            shape
                .fill(EllipticalGradient(
                    stops: stops,
                    center: UnitPoint(x: centerX, y: centerY),
                    startRadiusFraction: 0,
                    endRadiusFraction: radius
                ))
                .opacity(layer.opacity)
        case let .outline(width, blur):
            // Half of a stroke falls outside the shape, so it is drawn twice
            // as wide and cut to the shape.
            shape
                .stroke(layer.stops.first?.color.color ?? .white, lineWidth: width * 2 * scale)
                .blur(radius: blur * scale)
                .clipShape(shape)
                .opacity(layer.opacity)
        }
    }
}

/// A small closed notch wearing a glow theme, for Settings. The camera
/// housing in the middle is hardware and hides the glow, as on the Mac: what
/// shows is the two wings and the line under the camera.
struct MiniGlowNotch: View {
    let theme: GlowTheme
    let flows: Bool
    var brightness: Double = 1

    static let size = CGSize(width: 118, height: 24)

    var body: some View {
        let shape = CompactNotchIslandShape(lowerCut: 5)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            CompletionGlowFill(shape: shape, theme: theme, flows: flows, scale: 0.7)
                .opacity(brightness)
            UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5, style: .continuous)
                .fill(Color.black)
                .frame(width: Self.size.width * 0.54, height: Self.size.height * 0.66)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }
}

/// One theme in the picker: a tiny screen with the notch at its top edge,
/// glowing in the theme, and the theme's name.
struct GlowThemeSwatch: View {
    let theme: GlowTheme
    let selected: Bool
    /// Whether the miniature moves: the chosen theme and the one under the
    /// pointer do, the rest hold still.
    let flows: Bool
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        VStack(spacing: 7) {
            MiniGlowNotch(theme: theme, flows: flows)
            Text(theme.displayName)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(selected ? palette.accentColor.opacity(0.1) : palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? palette.accentColor : palette.hairlineColor, lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}
