import ChimloCore
import SwiftUI

// MARK: Miniature notch

/// The states the welcome's miniature notch plays through, in order.
enum MiniNotchState: CaseIterable {
    case idle
    case working
    case permission
    case question
    case done

    var caption: String {
        switch self {
        case .idle: "Quiet while you work"
        case .working: "Claude is working"
        case .permission: "Claude needs your permission"
        case .question: "Claude has a question"
        case .done: "Claude is done"
        }
    }

    /// How long each state holds, so the eye can follow the story.
    var seconds: Double {
        switch self {
        case .idle: 1.6
        case .working: 2.2
        case .permission, .question: 2.6
        case .done: 2.4
        }
    }

    var isExpanded: Bool { self == .permission || self == .question }

    var mood: AvatarMood {
        switch self {
        case .idle: .idle
        case .working: .working
        case .permission: .waiting
        case .question: .question
        case .done: .success
        }
    }
}

/// A miniature of the real notch, drawn with the app's own notch shapes,
/// pixel avatar, and completion wave, so the preview looks like the product.
struct MiniNotch: View {
    let state: MiniNotchState
    let reduceMotion: Bool

    static let compactSize = CGSize(width: 214, height: 30)
    static let expandedSize = CGSize(width: 330, height: 118)

    var body: some View {
        let size = state.isExpanded ? Self.expandedSize : Self.compactSize
        ZStack(alignment: .top) {
            if state.isExpanded {
                NotchExpandedIslandShape(lowerCut: 10).fill(Color.black)
                expandedContent
                    .padding(.top, 34)
                    .padding(.horizontal, 18)
                    .transition(.opacity)
            } else {
                CompactNotchIslandShape(lowerCut: 6).fill(Color.black)
                if state == .done {
                    SpectrumWaveFill(shape: CompactNotchIslandShape(lowerCut: 6), flows: !reduceMotion)
                        .transition(.opacity)
                }
            }
            wings
                .frame(width: size.width)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The avatar on the left wing, the camera in the middle, and the live
    /// signal on the right: the same layout as the real notch, spread to
    /// whatever width the notch currently has.
    private var wings: some View {
        HStack(spacing: 0) {
            PixelAvatar(
                mood: state.mood,
                seed: 3,
                size: 15,
                pixelUnit: 1.2,
                reduceMotion: reduceMotion,
                palette: .claudeOrange
            )
            .frame(width: 44, height: Self.compactSize.height)
            Spacer(minLength: 0)
            Circle()
                .fill(Color(white: 0.12))
                .frame(width: 6, height: 6)
                .overlay(Circle().fill(Color(white: 0.2)).frame(width: 2.5, height: 2.5))
            Spacer(minLength: 0)
            signal
                .frame(width: 44, height: Self.compactSize.height)
        }
        .frame(height: Self.compactSize.height)
    }

    @ViewBuilder
    private var signal: some View {
        switch state {
        case .working:
            PulsingDot(color: ChimloTheme.providerOrange, reduceMotion: reduceMotion)
        case .permission:
            Text("!").font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(ChimloTheme.attention)
        case .question:
            Text("?").font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(ChimloTheme.attention)
        case .idle, .done:
            Color.clear
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("my-app")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChimloTheme.paper)
                Spacer()
                Text("Needs you")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(ChimloTheme.attention)
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .background(ChimloTheme.attention.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if state == .permission {
                Text("Run: npm test")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChimloTheme.quietPaper)
                HStack(spacing: 6) {
                    Spacer()
                    MiniButton(title: "Deny", prominent: false)
                    MiniButton(title: "Allow once", prominent: true)
                }
            } else {
                Text("Which test runner should I use?")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChimloTheme.quietPaper)
                HStack(spacing: 6) {
                    MiniButton(title: "Vitest", prominent: true)
                    MiniButton(title: "Jest", prominent: false)
                    Spacer()
                }
            }
        }
    }
}

private struct MiniButton: View {
    let title: String
    let prominent: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : ChimloTheme.paper)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(prominent ? ChimloTheme.paper : Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct PulsingDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// The welcome's centrepiece: the top of a Mac screen with the miniature notch
/// playing through idle, working, permission, question, and done. It is a
/// picture of the product, not a session: nothing here touches real state.
struct NotchStoryboard: View {
    let reduceMotion: Bool
    @State private var state: MiniNotchState = .idle

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.09, green: 0.09, blue: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                menuBar
                MiniNotch(state: state, reduceMotion: reduceMotion)
            }
            .frame(width: 440, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            Text(state.caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SetupTheme.textTertiary)
                .id(state)
                .transition(.opacity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the notch: quiet while you work, then Claude working, asking for permission, asking a question, and finishing.")
        .task { await play() }
    }

    /// Plays the states in order, forever, until the screen goes away.
    private func play() async {
        let order = MiniNotchState.allCases
        var index = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(order[index].seconds * (reduceMotion ? 1.4 : 1)))
            guard !Task.isCancelled else { return }
            index = (index + 1) % order.count
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.82)) {
                state = order[index]
            }
        }
    }

    /// A hint of a menu bar, so the miniature reads as the top of a Mac and
    /// the notch sits where the real one does.
    private var menuBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo")
                .font(.system(size: 10))
            ForEach(Array([26.0, 22, 30].enumerated()), id: \.offset) { _, width in
                Capsule().frame(width: width, height: 4)
            }
            Spacer()
            ForEach(Array([14.0, 14, 34].enumerated()), id: \.offset) { _, width in
                Capsule().frame(width: width, height: 4)
            }
        }
        .foregroundStyle(Color.white.opacity(0.22))
        .padding(.horizontal, 16)
        .frame(height: MiniNotch.compactSize.height)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: Connection diagram

/// Claude Code → Claude Overhead → your notch. Light flows along whichever
/// link the running stage is building, and a failed link turns red.
struct ConnectionDiagram: View {
    enum Phase: Equatable {
        case connecting(SetupStage)
        case failed(SetupStage)
        case connected
    }

    let phase: Phase
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 0) {
            DiagramNode(title: "Claude Code", isLit: true) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SetupTheme.textPrimary)
            }
            DiagramLink(state: hooksLink, reduceMotion: reduceMotion)
            DiagramNode(title: "Claude Overhead", isLit: true) {
                PixelAvatar(
                    mood: overheadMood,
                    seed: 3,
                    size: 30,
                    reduceMotion: reduceMotion,
                    palette: .claudeOrange
                )
            }
            DiagramLink(state: notchLink, reduceMotion: reduceMotion)
            DiagramNode(title: "Your notch", isLit: notchLink == .done) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(notchLink == .done ? SetupTheme.textPrimary : SetupTheme.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Hooks and settings join Claude Code to Overhead.
    private var hooksLink: DiagramLink.State {
        switch phase {
        case let .connecting(stage): stage == .verifying ? .done : .flowing
        case let .failed(stage): stage == .verifying ? .done : .broken
        case .connected: .done
        }
    }

    /// Verification proves Overhead reaches the notch.
    private var notchLink: DiagramLink.State {
        switch phase {
        case let .connecting(stage): stage == .verifying ? .flowing : .idle
        case let .failed(stage): stage == .verifying ? .broken : .idle
        case .connected: .done
        }
    }

    private var overheadMood: AvatarMood {
        switch phase {
        case .connecting: .working
        case .failed: .failed
        case .connected: .success
        }
    }

    private var accessibilityDescription: String {
        switch phase {
        case let .connecting(stage): "Connecting Claude Code to Claude Overhead. \(stage.title)."
        case let .failed(stage): "The connection stopped while \(stage.title.lowercased())."
        case .connected: "Claude Code, Claude Overhead, and your notch are connected."
        }
    }
}

private struct DiagramNode<Icon: View>: View {
    let title: String
    let isLit: Bool
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SetupTheme.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isLit ? Color.white.opacity(0.14) : SetupTheme.hairline, lineWidth: 1)
                )
                .overlay(icon())
                .frame(width: 68, height: 68)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isLit ? SetupTheme.textSecondary : SetupTheme.textTertiary)
                .fixedSize()
        }
        .frame(width: 104)
    }
}

private struct DiagramLink: View {
    enum State: Equatable {
        case idle
        case flowing
        case done
        case broken
    }

    let state: State
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Capsule().fill(SetupTheme.hairline)
            switch state {
            case .idle:
                EmptyView()
            case .flowing:
                if reduceMotion {
                    Capsule().fill(SetupTheme.accent.opacity(0.55))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: max(0, phase - 0.35)),
                                    .init(color: SetupTheme.accent, location: phase),
                                    .init(color: .clear, location: min(1, phase + 0.02)),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    }
                }
            case .done:
                Capsule().fill(SetupTheme.accent)
                    .shadow(color: SetupTheme.accent.opacity(0.6), radius: 6)
            case .broken:
                Capsule()
                    .stroke(SetupTheme.danger, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        .frame(width: 72, height: 2)
        .padding(.bottom, 26)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: state)
    }
}
