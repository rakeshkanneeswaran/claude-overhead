import ChimloCore
import SwiftUI

/// Colours for context health, shared by the notch and the companion window.
enum ContextColors {
    static func color(for health: ContextHealth?) -> Color {
        switch health {
        case .critical: ChimloTheme.clayText
        case .attention: ChimloTheme.attention
        case .healthy, nil: ChimloTheme.liveGreen
        }
    }
}

/// A compact context-window meter: how full Claude's context is, coloured by
/// health. Marked approximate when the window size was inferred.
struct ContextMeter: View {
    let fraction: Double
    let health: ContextHealth
    var width: CGFloat = 44

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(ContextColors.color(for: health))
                    .frame(width: max(3, width * fraction))
            }
            .frame(width: width, height: 4)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ContextColors.color(for: health))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
    }
}

/// A tiny ring for the compact notch, where there is no room for a bar.
struct ContextRing: View {
    let fraction: Double
    let health: ContextHealth
    var size: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.04, fraction))
                .stroke(ContextColors.color(for: health), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
    }
}

/// One dot per running subagent, capped so the wing stays calm.
struct AgentDots: View {
    let count: Int
    var maximum = 4

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<min(count, maximum), id: \.self) { _ in
                Circle().fill(ChimloTheme.providerOrange).frame(width: 4, height: 4)
            }
            if count > maximum {
                Text("+\(count - maximum)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ChimloTheme.providerOrange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) agents working")
    }
}

/// The session row's second line: what Claude is doing, on which branch,
/// how full its context is, which agents run, and the linked pull request.
/// Every item appears only when its data is real.
struct SessionMetaLine: View {
    let session: SessionDisplayModel
    var attentionAt: Double = 0.7
    var criticalAt: Double = 0.9

    var body: some View {
        let insights = session.insights
        HStack(spacing: 8) {
            if session.mood == .working {
                Label(session.detail, systemImage: activitySymbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChimloTheme.providerOrange)
                    .lineLimit(1)
            }
            if let branch = insights?.gitBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let fraction = insights?.contextFraction {
                ContextMeter(
                    fraction: fraction,
                    health: ContextHealth.classify(fraction: fraction, attentionAt: attentionAt, criticalAt: criticalAt)
                )
            }
            if let running = insights?.runningAgents.count, running > 0 {
                HStack(spacing: 3) {
                    AgentDots(count: running)
                    Text(running == 1 ? "1 agent" : "\(running) agents")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ChimloTheme.quietPaper)
                }
            }
            if let pr = insights?.pullRequests.last {
                Text("#\(pr.number)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .accessibilityLabel("Pull request \(pr.number)")
            }
            if session.live?.kind == .background {
                Text("Background")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .padding(.horizontal, 5)
                    .frame(height: 14)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Spacer(minLength: 0)
        }
    }

    static func hasContent(_ session: SessionDisplayModel) -> Bool {
        session.mood == .working
            || session.insights?.gitBranch != nil
            || session.insights?.contextFraction != nil
            || (session.insights?.runningAgents.isEmpty == false)
            || session.live?.kind == .background
    }

    private var activitySymbol: String {
        switch session.detail {
        case ToolActivityKind.reading.label: "doc.text"
        case ToolActivityKind.writing.label: "pencil"
        case ToolActivityKind.executing.label: "terminal"
        case ToolActivityKind.searching.label: "magnifyingglass"
        case ToolActivityKind.delegating.label: "person.2"
        case ToolActivityKind.browsing.label: "globe"
        default: "sparkle"
        }
    }
}
