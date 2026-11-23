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

/// The session row's meta line: the latest tool call in Claude's words (or
/// the plain status while none is known), the project, running agents, the
/// linked pull request. Every item appears only when its data is real.
struct SessionMetaLine: View {
    let session: SessionDisplayModel
    var attentionAt: Double = 0.7
    var criticalAt: Double = 0.9
    var showsAgents = true
    static var height: CGFloat { SessionMetaLineMetrics.height }

    var body: some View {
        let insights = session.insights
        HStack(spacing: 8) {
            if let activity = session.activities.last {
                activityLabel(activity)
                    .layoutPriority(1)
            } else if session.isRunning {
                Label(session.detail, systemImage: activitySymbol)
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChimloTheme.providerOrange)
                    .lineLimit(1)
            }
            if let project = session.projectName, project != session.displayTitle {
                Label(project, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(ChimloTheme.mutedPaper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 110, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Project \(project)")
            }
            if showsAgents, let running = insights?.runningAgents.count, running > 0 {
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
        // Branch and context stay out of the notch row; the companion
        // window's Sessions page shows both.
        session.isRunning
            || !session.activities.isEmpty
            || (session.insights?.runningAgents.isEmpty == false)
            || session.live?.kind == .background
    }

    private var activitySymbol: String { ActivitySymbol.name(for: session.detail) }

    /// "Bash · Run tests", in orange while it runs; a finished session's last
    /// call stays readable, quieter, with its outcome.
    private func activityLabel(_ activity: SessionActivity) -> some View {
        let status = activity.presentedStatus(sessionIsWorking: session.isRunning)
        let isLive = session.isRunning && session.currentActivity?.id == activity.id
        let accent = status == .failed ? ChimloTheme.clayText
            : isLive ? ChimloTheme.providerOrange : ChimloTheme.quietPaper
        return HStack(spacing: 4) {
            Image(systemName: ActivitySymbol.name(for: activity.kind))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
            Text(activity.toolDisplayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .fixedSize()
            Text(activity.headline)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isLive ? ChimloTheme.paper.opacity(0.9) : ChimloTheme.quietPaper)
                .lineLimit(1)
                .truncationMode(activity.summary == nil && activity.targetIsPath ? .middle : .tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isLive ? "Now" : "Last"): \(activity.toolDisplayName), \(activity.headline), \(status.label)")
    }
}

/// Plain numbers, usable outside the main actor for row-height estimates.
enum SessionMetaLineMetrics {
    static let height: CGFloat = 17
}

enum ActivitySymbol {
    /// The symbol for a kind of tool call; `nil` is plain work.
    static func name(for kind: ToolActivityKind?) -> String {
        switch kind {
        case .reading: "doc.text"
        case .writing: "pencil"
        case .executing: "terminal"
        case .searching: "magnifyingglass"
        case .delegating: "person.2"
        case .browsing: "globe"
        case .asking: "questionmark.bubble"
        case .other, nil: "sparkle"
        }
    }

    /// The symbol for a live activity label from the hooks.
    static func name(for detail: String) -> String {
        switch detail {
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

/// What the closed notch's right wing shows when nothing needs the owner:
/// the layout decides which of activity, context and agents appear, and each
/// appears only when its data is real.
struct CompactWingIndicators: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        let spec = model.layoutSpec
        // The same session the closed notch's mark and activity line speak
        // for, so the wing never describes a different one.
        let session = model.notchFocusSession
            ?? model.sessions.first(where: \.isRunning)
            ?? model.sessions.first
        let insights = session?.insights
        let running = insights?.runningAgents.count ?? 0
        HStack(spacing: 3) {
            // The strip under the notch already names the tool; the wing
            // keeps the glyph only when there is no strip.
            if spec.showsActivityLabel, model.compactActivity == nil, let session, session.isRunning {
                Image(systemName: session.currentActivity.map { ActivitySymbol.name(for: $0.kind) }
                    ?? ActivitySymbol.name(for: session.detail))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ChimloTheme.providerOrange)
                    .accessibilityLabel(session.currentActivity?.toolDisplayName ?? session.detail)
            }
            if spec.showsContextIndicator, let fraction = insights?.contextFraction {
                ContextRing(
                    fraction: fraction,
                    health: ContextHealth.classify(
                        fraction: fraction,
                        attentionAt: model.contextAttentionThreshold,
                        criticalAt: model.contextCriticalThreshold
                    ),
                    size: 11
                )
            }
            if spec.showsAgentIndicator, running > 0 {
                AgentDots(count: running, maximum: spec.compactWingWidthScale > 1.3 ? 3 : 2)
            }
            // Lock Mode is visible without opening the notch: red and closed
            // while locked, a plain open lock otherwise.
            NotchLockGlyph(isLocked: model.isNotchLocked, size: 9)
            if model.github.showsInClosedNotch, let badge = GitHubBadge.from(model.github.indicator) {
                GitHubClosedNotchBadge(model: model, badge: badge)
            }
        }
    }
}

/// The lock's look, shared by the closed notch and the open notch's button.
struct NotchLockGlyph: View {
    let isLocked: Bool
    var size: CGFloat = 11

    static func color(isLocked: Bool) -> Color {
        isLocked ? ChimloTheme.signalRed : ChimloTheme.paper
    }

    var body: some View {
        Image(systemName: isLocked ? "lock.fill" : "lock.open")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Self.color(isLocked: isLocked))
            .accessibilityLabel(isLocked ? "Notch locked" : "Notch unlocked")
    }
}
