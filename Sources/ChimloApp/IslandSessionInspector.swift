import ChimloCore
import SwiftUI

// MARK: - Inspector

/// One session's live activity feed inside the open notch: every tool call
/// Claude made, in order, with its status, as the transcript records it.
struct SessionInspectorView: View {
    let session: SessionDisplayModel
    let reduceMotion: Bool
    let back: () -> Void
    let focusTerminal: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ActivityFeedView(
                activities: session.activities,
                sessionIsWorking: session.isRunning,
                hasTranscript: session.insights != nil,
                reduceMotion: reduceMotion
            )
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity for \(session.displayTitle)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Sessions")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(ChimloTheme.quietPaper)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(ChimloTheme.badgeInk)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to all sessions")
            .accessibilityLabel("Back to all sessions")

            ClaudeCodeMark(mood: session.mood, size: 24, reduceMotion: reduceMotion)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ChimloTheme.paper)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(subtitle(now: timeline.date))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ChimloTheme.mutedPaper)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            RunStateBadge(state: session.runState, reduceMotion: reduceMotion)

            if let focusTerminal {
                Button(action: focusTerminal) {
                    Image(systemName: "macwindow.and.cursorarrow")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChimloTheme.quietPaper)
                        .frame(width: 26, height: 24)
                        .background(ChimloTheme.badgeInk)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.terminal.map { "Focus \($0)" } ?? "Focus terminal")
                .accessibilityLabel(session.terminal.map { "Focus \($0)" } ?? "Focus terminal")
            }
        }
    }

    private func subtitle(now: Date) -> String {
        var parts: [String] = []
        if let project = session.projectName, project != session.displayTitle { parts.append(project) }
        if let model = session.model, !model.isEmpty { parts.append(model) }
        let age = SessionRelativeTime.shortLabel(since: session.updatedAt, now: now)
        parts.append(age == "now" ? "active now" : "active \(age) ago")
        return parts.joined(separator: " · ")
    }
}

/// The feed itself. Oldest at the top, newest at the bottom; it follows new
/// entries only while the owner is already at the bottom, so scrolling back
/// to read an older call is never interrupted.
struct ActivityFeedView: View {
    let activities: [SessionActivity]
    let sessionIsWorking: Bool
    let hasTranscript: Bool
    let reduceMotion: Bool

    @State private var isPinnedToBottom = true
    @State private var viewportHeight: CGFloat = 0

    private static let bottomID = "feed-bottom"
    private static let space = "activity-feed"

    var body: some View {
        if activities.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(activities) { activity in
                            ActivityFeedRow(
                                activity: activity,
                                status: activity.presentedStatus(sessionIsWorking: sessionIsWorking),
                                reduceMotion: reduceMotion
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: FeedBottomKey.self,
                                        value: geometry.frame(in: .named(Self.space)).maxY
                                    )
                                }
                            }
                    }
                    .padding(.bottom, 4)
                }
                .coordinateSpace(name: Self.space)
                .scrollIndicators(.automatic)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: FeedViewportKey.self, value: geometry.size.height)
                    }
                }
                .onPreferenceChange(FeedViewportKey.self) { height in
                    Task { @MainActor in viewportHeight = height }
                }
                .onPreferenceChange(FeedBottomKey.self) { bottom in
                    Task { @MainActor in
                        // Within a few points of the end counts as the end.
                        isPinnedToBottom = viewportHeight == 0 || bottom <= viewportHeight + 12
                    }
                }
                .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                .onChange(of: activities.last?.id) { _, _ in
                    guard isPinnedToBottom else { return }
                    if reduceMotion {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
            }
            .background(ChimloTheme.raisedInk)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ChimloTheme.mutedPaper)
            Text(hasTranscript ? "No tool calls yet" : "Waiting for this session's transcript")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChimloTheme.quietPaper)
            Text("Each tool Claude runs in this session shows up here as it happens.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(ChimloTheme.mutedPaper)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChimloTheme.raisedInk)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FeedBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct FeedViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One tool call: status, tool, Claude's description, and what it acted on.
struct ActivityFeedRow: View {
    let activity: SessionActivity
    let status: ActivityStatus
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ActivityStatusGlyph(status: status, reduceMotion: reduceMotion)
                .frame(width: 12)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label {
                        Text(activity.toolDisplayName)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: ActivitySymbol.name(for: activity.kind))
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status == .running ? ChimloTheme.providerOrange : ChimloTheme.quietPaper)
                    .fixedSize()

                    Text(activity.headline)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChimloTheme.paper.opacity(status == .running ? 1 : 0.88))
                        .lineLimit(2)
                        .truncationMode(activity.summary == nil && activity.targetIsPath ? .middle : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if activity.summary != nil, let target = activity.target {
                    Text(target)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChimloTheme.mutedPaper)
                        .lineLimit(1)
                        .truncationMode(activity.targetIsPath ? .middle : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text(timeLabel)
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(ChimloTheme.mutedPaper)
                .fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status == .running ? ChimloTheme.providerOrange.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var timeLabel: String {
        guard let startedAt = activity.startedAt else { return "" }
        var label = startedAt.formatted(date: .omitted, time: .standard)
        if let finishedAt = activity.finishedAt, status == .completed || status == .failed {
            let seconds = max(0, finishedAt.timeIntervalSince(startedAt))
            if seconds >= 1 { label += " · " + Self.duration(seconds) }
        }
        return label
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3_600)h \(whole % 3_600 / 60)m"
    }

    private var accessibilityText: String {
        var parts = [activity.toolDisplayName, activity.headline]
        if activity.summary != nil, let target = activity.target { parts.append(target) }
        parts.append(status.label)
        return parts.joined(separator: ", ")
    }
}

/// Running pulses, and holds still with Reduce Motion. Done, failed and
/// unknown are shapes as well as colours, so they read without colour.
struct ActivityStatusGlyph: View {
    let status: ActivityStatus
    let reduceMotion: Bool
    @State private var dimmed = false

    var body: some View {
        switch status {
        case .running:
            Circle()
                .fill(ChimloTheme.providerOrange)
                .frame(width: 6, height: 6)
                .opacity(dimmed ? 0.35 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dimmed = true }
                }
                .onDisappear { dimmed = false }
                .accessibilityHidden(true)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(ChimloTheme.liveGreen)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(ChimloTheme.clayText)
                .accessibilityHidden(true)
        case .unknown:
            Image(systemName: "minus")
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(ChimloTheme.mutedPaper)
                .accessibilityHidden(true)
        }
    }
}

/// The session's standing, as one short word.
struct RunStateBadge: View {
    let state: SessionRunState
    let reduceMotion: Bool
    var isHovering = false
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 4) {
            if state == .running {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .opacity(dimmed ? 0.3 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dimmed = true }
                    }
                    .onDisappear { dimmed = false }
            }
            Text(Self.label(state))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .fixedSize(horizontal: true, vertical: false)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
    }

    static func label(_ state: SessionRunState) -> String {
        switch state {
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .running: "Running"
        case .waitingInput: "Your turn"
        case .recentlyCompleted: "Done"
        case .older: "Idle"
        }
    }

    private var color: Color {
        switch state {
        case .needsYou: ChimloTheme.attention
        case .failed: ChimloTheme.clayText
        case .running: ChimloTheme.providerOrange
        case .waitingInput: ChimloTheme.paper
        case .recentlyCompleted: ChimloTheme.liveGreen
        case .older: ChimloTheme.quietPaper
        }
    }

    private var background: Color {
        switch state {
        case .older, .waitingInput: isHovering ? ChimloTheme.hoveredBadgeInk : ChimloTheme.badgeInk
        default: color.opacity(isHovering ? 0.24 : 0.15)
        }
    }
}

/// Where a row's jump mark sits, so a separate button can cover it.
struct JumpMarkAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
