import AppKit
import ChimloCore
import ChimloProtocol
import SwiftUI

private let expandedHorizontalGutter: CGFloat = 16

struct IslandRootView: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var github: GitHubModel
    let openSettings: () -> Void

    var body: some View {
        GeometryReader { hostGeometry in
            GeometryReader { islandGeometry in
                ZStack(alignment: .top) {
                    islandSurface

                    switch model.panelMode {
                    case .compact:
                        CompactIslandView(model: model)
                            .padding(.horizontal, model.islandLayout.hasCameraHousing ? 0 : 13)
                            .padding(.vertical, model.islandLayout.hasCameraHousing ? 0 : 5)
                    case .sessions where model.notchContent == .github:
                        if model.islandLayout.hasCameraHousing {
                            ExpandedStatusBand(model: model, openSettings: openSettings)
                        }
                        GitHubNotchPanel(model: model, github: github)
                            .padding(.horizontal, expandedHorizontalGutter)
                            .padding(.top, model.islandLayout.hasCameraHousing ? model.islandLayout.expandedContentTopInset + 2 : 10)
                            .padding(.bottom, 10)
                            .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
                            .frame(width: islandGeometry.size.width, alignment: .center)
                            .overlay(alignment: .topTrailing) { standaloneGitHubButton }
                            .transition(.opacity)
                    case .sessions:
                        if model.islandLayout.hasCameraHousing {
                            ExpandedStatusBand(model: model, openSettings: openSettings)
                        }
                        let showsUsage = model.showsUsageDetails && model.inspectedSession == nil
                        if showsUsage {
                            UsageDashboardView(model: model)
                                .padding(.horizontal, expandedHorizontalGutter)
                                .padding(.top, model.islandLayout.expandedContentTopInset + 2)
                        }
                        SessionListView(model: model)
                            .padding(.horizontal, expandedHorizontalGutter)
                            .padding(
                                .top,
                                model.islandLayout.expandedContentTopInset
                                    + 2
                                    + (showsUsage ? model.usageDetailsHeight : 0)
                            )
                            .padding(.bottom, 10)
                            .frame(width: model.panelSize.width)
                            .frame(width: islandGeometry.size.width, alignment: .center)
                            .overlay(alignment: .topTrailing) { standaloneGitHubButton }
                            .transition(.opacity)
                    case .update:
                        if let presentation = model.updatePresentation {
                            UpdateReminderView(model: model, presentation: presentation)
                                .frame(width: model.panelSize.width, height: 52, alignment: .top)
                                .padding(.top, max(model.islandLayout.expandedContentTopInset, 4))
                                .frame(width: islandGeometry.size.width, alignment: .center)
                        }
                    case .onboarding:
                        OnboardingView(model: model)
                    }
                }
                // Follow the live SwiftUI bounds while the visible island grows
                // inside the fixed AppKit host. WindowServer now sees one stable
                // frame across Spaces instead of an in-flight window resize.
                .frame(width: islandGeometry.size.width, height: islandGeometry.size.height)
                .clipped()
            }
            .frame(width: model.panelSize.width, height: model.panelSize.height)
            .animation(islandResizeAnimation, value: model.panelSize)
            .contextMenu {
                Button("Settings…", action: openSettings)
                Divider()
                Button("Quit Claude Overhead") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .frame(
                width: hostGeometry.size.width,
                height: hostGeometry.size.height,
                alignment: .top
            )
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Overhead activity island")
    }

    /// Displays without a notch have no status band, so the GitHub button
    /// sits in the panel's corner instead.
    @ViewBuilder
    private var standaloneGitHubButton: some View {
        if !model.islandLayout.hasCameraHousing, model.github.showsButton {
            GitHubNotchButton(model: model).padding(.trailing, 6).padding(.top, 2)
        }
    }

    private var islandResizeAnimation: Animation? {
        guard !model.accessibility.reduceMotion else { return nil }
        return .timingCurve(0.32, 0.72, 0, 1, duration: 0.24)
    }

    @ViewBuilder
    private var islandSurface: some View {
        let surface = ChimloTheme.surface(increasedContrast: model.accessibility.increaseContrast)
        if model.islandLayout.hasCameraHousing, model.panelMode == .compact {
            CompactNotchIslandShape()
                .fill(surface)
                .overlay { completionGlow(in: CompactNotchIslandShape()) }
        } else if model.islandLayout.hasCameraHousing {
            NotchExpandedIslandShape()
                .fill(surface)
        } else {
            let compact = model.panelMode == .compact
            let shape = ChamferedIslandShape(
                shoulder: compact ? 9 : 12,
                lowerCut: compact ? 9 : 14
            )
            shape
                .fill(surface)
                .overlay { if compact { completionGlow(in: shape) } }
        }
    }

    /// A finished turn floods the compact notch with the colour wave for a
    /// moment. The open panel already shows the reply, so only the compact
    /// shape carries it.
    private func completionGlow<S: Shape>(in shape: S) -> some View {
        Group {
            if model.animatesCompletionGlow {
                SpectrumWaveFill(shape: shape, flows: !model.reducesMotion)
                    .opacity(model.showsCompletionGlow ? max(0.25, model.glowIntensity) : 0)
                    .animation(
                        .easeInOut(duration: model.showsCompletionGlow
                            ? 0.35
                            : IslandCollapsePolicy.completionGlowFadeSeconds),
                        value: model.showsCompletionGlow
                    )
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.animatesCompletionGlow)
    }
}

/// The colour spectrum flowing across the whole compact notch, like Razer
/// Chroma's "wave": every colour spread evenly across the width and sliding
/// sideways. It fills the notch's own shape, so it follows every corner.
enum SpectrumWaveStyle {
    static let secondsPerCycle: Double = 3
    // Two cycles back to back: the notch shows one and slides across them, so
    // the wave loops without a seam. Slightly below full brightness keeps the
    // avatar and labels on top readable.
    static let colors: [Color] = (0...24).map {
        Color(hue: Double($0 % 12) / 12, saturation: 0.75, brightness: 0.88)
    }
}

struct SpectrumWaveFill<S: Shape>: View {
    let shape: S
    let flows: Bool

    var body: some View {
        // 60 fps is plenty for a slow wave and halves the redraw cost on ProMotion.
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !flows)) { context in
            let seconds = SpectrumWaveStyle.secondsPerCycle
            let phase = flows
                ? context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: seconds) / seconds
                : 0
            // A horizontal wave spreads every colour evenly across a wide,
            // flat notch; a rotating angular gradient bunches them up.
            shape.fill(LinearGradient(
                colors: SpectrumWaveStyle.colors,
                startPoint: UnitPoint(x: phase - 1, y: 0.5),
                endPoint: UnitPoint(x: phase + 1, y: 0.5)
            ))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct UpdateReminderView: View {
    @ObservedObject var model: ApplicationModel
    let presentation: AppUpdatePresentation
    @State private var isHovering = false

    var body: some View {
        Button(action: model.installUpdate) {
            HStack(spacing: 10) {
                updateMark
                    .frame(width: 18, height: 18)
                    .offset(y: arrowOffset)

                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(UpdateReminderButtonStyle())
        .disabled(!presentation.isActionable)
        .onHover { isHovering = $0 }
        .animation(
            model.accessibility.reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovering
        )
        .accessibilityLabel(presentation.title)
        .accessibilityHint(accessibilityHint)
    }

    private var arrowOffset: CGFloat {
        guard presentation.isActionable, isHovering, !model.accessibility.reduceMotion else { return 0 }
        return 1
    }

    private var labelColor: Color {
        if !presentation.isActionable { return ChimloTheme.quietPaper }
        return isHovering ? ChimloTheme.paper : ChimloTheme.quietPaper
    }

    private var accessibilityHint: String {
        switch presentation.phase {
        case .available:
            "Downloads, installs, and relaunches Claude Overhead. Your settings stay unchanged."
        case .upToDate, .failed:
            "Checks for updates."
        case .checking, .downloading, .preparing, .installing:
            "Claude Overhead is updating."
        }
    }

    @ViewBuilder
    private var updateMark: some View {
        switch presentation.phase {
        case .available:
            PixelUpdateArrow(color: labelColor)
        case .upToDate:
            PixelText(text: "OK", pixelSize: 1.5, color: ChimloTheme.moss, spacing: 1)
        case .failed:
            PixelText(text: "!", pixelSize: 2, color: ChimloTheme.clayText, spacing: 1)
        case .checking, .preparing, .installing:
            PixelUpdateProgress(progress: nil, color: ChimloTheme.quietPaper)
        case .downloading:
            PixelUpdateProgress(
                progress: presentation.normalizedProgress,
                color: ChimloTheme.paper
            )
        }
    }
}

private struct UpdateReminderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? ChimloTheme.selectedInk.opacity(0.44)
                    : Color.clear
            )
    }
}

private struct PixelUpdateArrow: View {
    let color: Color

    var body: some View {
        ZStack {
            Rectangle()
                .fill(color)
                .frame(width: 3, height: 9)
                .offset(y: -2)
            Rectangle()
                .fill(color)
                .frame(width: 3, height: 3)
                .offset(x: -3, y: 2)
            Rectangle()
                .fill(color)
                .frame(width: 3, height: 3)
                .offset(x: 3, y: 2)
            Rectangle()
                .fill(color)
                .frame(width: 9, height: 2)
                .offset(y: 7)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

private struct PixelUpdateProgress: View {
    let progress: Double?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 0.22,
                paused: progress != nil || reduceMotion
            )
        ) { context in
            HStack(spacing: 1) {
                ForEach(0..<4, id: \.self) { index in
                    Rectangle()
                        .fill(
                            isLit(index: index, at: context.date)
                                ? color
                                : ChimloTheme.mutedPaper.opacity(0.28)
                        )
                        .frame(width: 3, height: 9)
                }
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    private var litCellCount: Int {
        guard let progress else { return 0 }
        return min(4, max(0, Int(ceil(progress * 4))))
    }

    private func isLit(index: Int, at date: Date) -> Bool {
        if progress != nil { return index < litCellCount }
        if reduceMotion { return index == 0 }
        let frame = Int(date.timeIntervalSinceReferenceDate / 0.22)
        return index == frame % 4
    }
}

private struct ExpandedStatusBand: View {
    @ObservedObject var model: ApplicationModel
    let openSettings: () -> Void

    var body: some View {
        Group {
            GeometryReader { geometry in
                let cameraWidth = min(model.islandLayout.cameraHousingWidth, geometry.size.width)
                let wingWidth = max(0, (geometry.size.width - cameraWidth) / 2)

                HStack(spacing: 0) {
                    Group {
                        if model.notchContent == .github {
                            GitHubModeWing(model: model)
                        } else if model.layoutSpec.expandedShowsUsage {
                            InlineCapacityView(model: model)
                        } else {
                            Color.clear
                        }
                    }
                        .padding(.leading, expandedHorizontalGutter)
                        .frame(width: wingWidth, height: geometry.size.height, alignment: .leading)
                        .clipped()

                    Color.clear
                        .frame(width: cameraWidth, height: geometry.size.height)
                        .accessibilityHidden(true)

                    HStack(spacing: 0) {
                        if model.github.showsButton {
                            GitHubNotchButton(model: model)
                        }
                        if let toggleFocusMode = model.toggleFocusMode {
                            Button(action: toggleFocusMode) {
                                Image(systemName: model.isFocusModeActive ? "moon.fill" : "moon")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(
                                ExpandedControlButtonStyle(
                                    color: model.isFocusModeActive ? ChimloTheme.providerOrange : ChimloTheme.quietPaper
                                )
                            )
                            .help(model.isFocusModeActive ? "Turn off Focus mode" : "Turn on Focus mode")
                            .accessibilityLabel(model.isFocusModeActive ? "Turn off Focus mode" : "Turn on Focus mode")
                        }

                        Button {
                            model.soundsEnabled.toggle()
                        } label: {
                            Image(systemName: model.soundsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(
                            ExpandedControlButtonStyle(
                                color: model.soundsEnabled ? ChimloTheme.paper : ChimloTheme.clayText
                            )
                        )
                        .help(model.soundsEnabled ? "Mute Claude Overhead sounds" : "Unmute Claude Overhead sounds")
                        .accessibilityLabel(model.soundsEnabled ? "Mute Claude Overhead sounds" : "Unmute Claude Overhead sounds")
                        .accessibilityValue(model.soundsEnabled ? "Sounds on" : "Sounds muted")

                        Button(action: openSettings) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(ExpandedControlButtonStyle(color: ChimloTheme.quietPaper))
                        .help("Open Claude Overhead settings")
                        .accessibilityLabel("Open Claude Overhead settings")
                    }
                    .padding(.trailing, expandedHorizontalGutter)
                    .frame(width: wingWidth, height: geometry.size.height, alignment: .trailing)
                    .clipped()
                }
            }
        }
        .frame(height: model.islandLayout.expandedContentTopInset)
    }
}

private struct ExpandedControlButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color.opacity(configuration.isPressed ? 0.55 : 1))
            .frame(width: 25, height: 26)
            .contentShape(Rectangle())
    }
}

private struct CompactIslandView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        openPanelButton {
            if model.islandLayout.hasCameraHousing {
                notchContent
            } else {
                standardContent
            }
        }
        .accessibilityLabel(compactAccessibilityLabel)
    }

    private func openPanelButton<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: model.openPanel) {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var compactAccessibilityLabel: String {
        "Open Claude Overhead. \(summary). \(model.compactLabel.lowercased())."
    }

    private var standardContent: some View {
        HStack(spacing: 9) {
            ClaudeCodeMark(
                mood: model.activeMood,
                size: 31,
                reduceMotion: model.accessibility.reduceMotion
            )
            if let line = model.compactActivity {
                CompactActivityStripView(line: line, reduceMotion: model.reducesMotion, fontSize: 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                PixelText(text: model.compactLabel, pixelSize: 1.7, spacing: 1)
                Spacer(minLength: 5)
            }
        }
    }

    private var notchContent: some View {
        VStack(spacing: 0) {
            wings
            if let line = model.compactActivity {
                CompactActivityStripView(line: line, reduceMotion: model.reducesMotion)
                    .padding(.horizontal, 12)
                    .frame(width: model.islandLayout.compactWidth, height: CompactActivityStrip.height, alignment: .top)
            }
        }
        .frame(width: model.islandLayout.compactWidth, alignment: .top)
    }

    private var wings: some View {
        HStack(spacing: 0) {
            leadingWing
            .frame(
                width: model.islandLayout.activityWingWidth,
                height: model.islandLayout.compactHeight,
                alignment: .center
            )

            Color.clear
                .frame(
                    width: model.islandLayout.cameraHousingWidth,
                    height: model.islandLayout.compactHeight
                )

            ZStack {
                // Keep this wing in the layout even when there is no warning
                // or owner-interaction signal to draw. EmptyView does
                // not retain its frame, which otherwise shifts the avatar by
                // half of the missing 32-point wing toward the camera housing.
                Color.clear
                compactTrailingSignal
            }
                .frame(
                    width: model.islandLayout.activityWingWidth,
                    height: model.islandLayout.compactHeight,
                    alignment: .center
                )
        }
    }

    /// The avatar, or in the Focus layout a still dot that only changes
    /// colour, so nothing moves at the edge of the owner's vision.
    @ViewBuilder
    private var leadingWing: some View {
        if model.layoutSpec.showsAvatar {
            ClaudeCodeMark(
                mood: model.activeMood,
                size: 17,
                reduceMotion: model.reducesMotion
            )
            .offset(x: 1.5)
        } else {
            Circle()
                .fill(focusDotColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }

    private var focusDotColor: Color {
        switch model.activeMood {
        case .working: ChimloTheme.providerOrange
        case .waiting, .question: ChimloTheme.attention
        case .failed: ChimloTheme.clayText
        case .success: ChimloTheme.liveGreen
        case .idle: ChimloTheme.mutedPaper
        }
    }

    @ViewBuilder
    private var compactTrailingSignal: some View {
        if model.pendingDecision != nil || model.sessions.contains(where: { $0.mood == .waiting }) {
            compactSignalText("!", color: model.pendingDecision != nil ? ChimloTheme.paper : ChimloTheme.attention)
        } else if model.sessions.contains(where: { $0.mood == .question }) {
            compactSignalText("?", color: ChimloTheme.attention)
        } else if model.sessions.contains(where: { $0.mood == .failed }) {
            compactSignalText("×", color: ChimloTheme.clayText)
        } else {
            CompactWingIndicators(model: model)
        }
    }

    private func compactSignalText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .monospacedDigit()
    }

    private var summary: String {
        if model.sessions.isEmpty { return "no sessions" }
        if model.sessions.count == 1 { return "1 session" }
        return "\(model.sessions.count) sessions"
    }
}

private struct InlineCapacityView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        let claude = model.capacityReading(provider: .claude, kind: .weekly)
        let help = capacityDisclosureHelp(
            claudeReading: claude,
            isExpanded: model.showsUsageDetails
        )

        Button(action: model.toggleUsageDetails) {
            ViewThatFits(in: .horizontal) {
                providerIndicator(
                    reading: claude,
                    segmentWidth: 3,
                    segmentCount: 5,
                    percentageSize: 10,
                    percentageWidth: 32
                )
                providerIndicator(
                    reading: claude,
                    segmentWidth: 2.5,
                    segmentCount: 4,
                    percentageSize: 9,
                    percentageWidth: 27
                )
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(CapacityDisclosureButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(model.showsUsageDetails ? "Expanded" : "Collapsed")
    }

    private func providerIndicator(
        reading: CapacityReading,
        segmentWidth: CGFloat,
        segmentCount: Int,
        percentageSize: CGFloat,
        percentageWidth: CGFloat
    ) -> some View {
        HStack(spacing: 2) {
            PixelCapacityGauge(
                reading: reading,
                segmentWidth: segmentWidth,
                segmentHeight: 7,
                segmentCount: segmentCount,
                segmentSpacing: 1,
                // Header shows remaining %, so fill the bar to match that
                // number rather than the consumed amount.
                usedOverride: reading.remainingPercentage
            )
            capacityPercentage(
                reading,
                fontSize: percentageSize,
                width: percentageWidth
            )
        }
    }

    private func capacityPercentage(
        _ reading: CapacityReading,
        fontSize: CGFloat,
        width: CGFloat
    ) -> some View {
        Text(capacityPercentageText(reading))
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(capacityColor(reading))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
            .frame(width: width, alignment: .leading)
    }
}

private struct CapacityDisclosureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.58 : 1)
    }
}

private struct UsageDashboardView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        let panelShape = ChamferedIslandShape(shoulder: 6, lowerCut: 6)

        // Exactly the limits Claude Code reports: no 5-hour row on plans
        // without one, and a row for each per-model weekly limit.
        let rows = model.claudeCapacityRows
        HStack(alignment: .top, spacing: 16) {
            UsageProviderBlock(
                readings: rows.map { (label: $0.row.label, name: $0.row.name, reading: $0.reading) },
                now: model.capacityClock
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity)
        .frame(height: CapacityLayout.detailsHeight(rows: rows.count), alignment: .top)
        .background(
            panelShape.fill(
                ChimloTheme.raisedSurface(increasedContrast: model.accessibility.increaseContrast)
            )
        )
        .overlay(
            panelShape.stroke(ChimloTheme.selectedInk.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct UsageProviderBlock: View {
    let readings: [(label: String, name: String, reading: CapacityReading)]
    let now: Date

    /// One label column for every row, as wide as the longest label, so the
    /// gauges still line up when a model row ("FABLE") joins "7D".
    private var labelWidth: CGFloat {
        let longest = readings.map(\.label.count).max() ?? 2
        return max(15, CGFloat(longest) * 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                PixelText(text: "CLAUDE", pixelSize: 1, color: ChimloTheme.providerOrange, spacing: 1)

                if let freshness {
                    PixelText(text: freshness.text, pixelSize: 1, color: ChimloTheme.mutedPaper, spacing: 1)
                        .opacity(freshness.stale ? 0.4 : 0.85)
                        .accessibilityLabel("Updated \(freshness.text.lowercased()) ago.")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(readings.enumerated()), id: \.offset) { _, item in
                    UsageLimitBlock(
                        label: item.label,
                        name: item.name,
                        labelWidth: labelWidth,
                        reading: item.reading,
                        now: now
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "Last updated" age shown beside the provider name; dimmed further once the
    // data is stale past the freshness window so a failed or slow fetch is
    // visible rather than confident stale numbers.
    private var freshness: (text: String, stale: Bool)? {
        guard let updated = readings.first?.reading.lastUpdatedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince(updated))
        return (compactAge(elapsed), elapsed > CapacityPolicy.freshnessInterval)
    }

    private func compactAge(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "NOW" }
        if minutes < 60 { return "\(minutes)M" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)H" }
        return "\(hours / 24)D"
    }
}

private struct UsageLimitBlock: View {
    /// The short pixel label, such as "7D" or "FABLE".
    let label: String
    /// The limit in words, such as "Fable weekly", for help and VoiceOver.
    let name: String
    var labelWidth: CGFloat = 15
    let reading: CapacityReading
    let now: Date

    var body: some View {
        capacityRow
            .help(rowHelp(label: name, reading: reading))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowHelp(label: name, reading: reading))
    }

    // LABEL · gauge · PERCENT · RESET — label sits on the left, the reset
    // countdown is pinned inline on the right. The gauge flexes to fill, so the
    // reset always has room and is shown.
    private var capacityRow: some View {
        mainRowContent(includesReset: true)
            .frame(height: 16, alignment: .leading)
    }

    private func mainRowContent(includesReset: Bool) -> some View {
        // At the limit the remaining percentage is always "0%" and tells you
        // nothing — blank that cell and surface the reset countdown in red in
        // its own (already reserved) column. Every frame is retained so the
        // row does not reflow.
        let atLimit = reading.isExhausted
        let reset = includesReset ? resetDuration(reading, now: now) : nil
        let hidePercent = atLimit && reset != nil
        return HStack(spacing: 5) {
            rowLabel(label)

            gauge(
                usedOverride: reading.remainingPercentage,
                colorOverride: atLimit ? ChimloTheme.clayText.opacity(0.4) : nil
            )

            if hidePercent {
                percentText("", color: .clear)
            } else {
                percentText(
                    capacityPercentageText(reading),
                    color: capacityColor(reading)
                )
            }

            trailingText(
                reset ?? "",
                color: atLimit && reset != nil ? ChimloTheme.clayText : ChimloTheme.quietPaper
            )
            .accessibilityHidden(reset == nil)
        }
    }

    // Fixed column so gauges line up across rows, with a deliberate gap
    // between the window label and the bar.
    private func rowLabel(_ text: String) -> some View {
        PixelText(text: text, pixelSize: 1, color: ChimloTheme.quietPaper, spacing: 1)
            .frame(width: labelWidth, alignment: .leading)
    }

    private func gauge(usedOverride: Double?, colorOverride: Color?) -> some View {
        PixelCapacityGauge(
            reading: reading,
            segmentWidth: 5,
            segmentHeight: 8,
            segmentCount: 10,
            fillsWidth: true,
            usedOverride: usedOverride,
            colorOverride: colorOverride
        )
    }

    private func percentText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .monospacedDigit()
            .frame(width: 34, alignment: .leading)
            .padding(.leading, 2)
    }

    // Fixed column so every row's gauge ends at the same x (7d and 5h rows
    // line up) and the reset stays pinned to the right edge, away from the
    // percentage which hugs the bar.
    private func trailingText(_ text: String, color: Color = ChimloTheme.quietPaper) -> some View {
        PixelText(text: text, pixelSize: 1, color: color, spacing: 1)
            .frame(width: 42, alignment: .trailing)
    }
}

private struct PixelCapacityGauge: View {
    let reading: CapacityReading
    var segmentWidth: CGFloat = 5
    var segmentHeight: CGFloat = 7
    var segmentCount = 5
    var segmentSpacing: CGFloat = 2
    // When true the segments stretch to fill the available width instead of
    // using a fixed segmentWidth, so the bar spans the full row.
    var fillsWidth = false
    // When set, the gauge fills by this percentage (0...100), or in the given
    // color, instead of deriving both from the reading.
    var usedOverride: Double?
    var colorOverride: Color?

    var body: some View {
        HStack(spacing: segmentSpacing) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Rectangle()
                    .fill(fillStyle(for: index))
                    .frame(
                        width: fillsWidth ? nil : segmentWidth,
                        height: segmentHeight
                    )
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .accessibilityHidden(true)
    }

    private enum SegmentState { case lit, dimmed, empty }

    private var usedValue: Double? {
        if let usedOverride { return usedOverride }
        if let reading = reading.usedPercentage { return reading }
        return nil
    }

    private func fillStyle(for index: Int) -> Color {
        switch segmentState(index) {
        case .lit:    return fillColor
        case .dimmed: return fillColor.opacity(0.4)
        case .empty:  return ChimloTheme.mutedPaper.opacity(0.24)
        }
    }

    // The bar fills as capacity is consumed: a full bar means fully used.
    // Blocks light only once a whole segment's worth is used (round down, not
    // to nearest). Any leftover fraction below a full block shows as a single
    // dimmed block rather than lighting a whole one.
    private func segmentState(_ index: Int) -> SegmentState {
        guard let used = usedValue, used > 0 else { return .empty }
        let percentagePerSegment = 100 / Double(segmentCount)
        let fullSegments = min(segmentCount, Int((used / percentagePerSegment).rounded(.down)))
        if index < fullSegments { return .lit }
        let hasPartial = fullSegments < segmentCount
            && used - Double(fullSegments) * percentagePerSegment > 0
        if index == fullSegments && hasPartial { return .dimmed }
        return .empty
    }

    private var fillColor: Color {
        colorOverride ?? capacityColor(reading)
    }
}

private func capacityPercentageText(_ reading: CapacityReading) -> String {
    guard let remaining = reading.remainingPercentage else { return "—%" }
    return "\(Int(remaining.rounded()))%"
}

// Urgency comes from colour, not row position: any bar and its percentage go
// amber above 80% used and red at 100%, on whichever row it sits.
private func capacityColor(_ reading: CapacityReading) -> Color {
    guard let used = reading.usedPercentage else { return ChimloTheme.mutedPaper }
    if used >= 100 { return ChimloTheme.clayText }
    if used > 80 { return ChimloTheme.attention }
    return ChimloTheme.providerOrange
}

private func capacityDisclosureHelp(
    claudeReading reading: CapacityReading,
    isExpanded: Bool
) -> String {
    let action = isExpanded ? "Hide all usage limits." : "Show all usage limits."
    guard let remaining = reading.remainingPercentage else {
        return "Claude weekly usage unavailable. \(action)"
    }
    let qualifier = reading.isApproximate ? "approximately " : ""
    return "Claude weekly capacity: \(qualifier)\(Int(remaining.rounded())) percent remaining. \(action)"
}

private func resetDuration(_ reading: CapacityReading, now: Date) -> String? {
    guard let window = reading.window, let reset = window.resetsAt else { return nil }
    return compactDuration(until: reset, now: now).uppercased()
}

private func rowHelp(
    label: String,
    reading: CapacityReading
) -> String {
    let name = "Claude"
    guard let window = reading.window, let remaining = reading.remainingPercentage else {
        if let lastUpdatedAt = reading.lastUpdatedAt {
            return "\(name) \(label) usage unavailable. Last updated \(exactTimestamp(lastUpdatedAt))."
        }
        return "\(name) \(label) usage unavailable."
    }
    let qualifier = reading.isApproximate ? "Approximately " : ""
    let reset = window.resetsAt.map { " Resets \(exactTimestamp($0))." } ?? " Reset time unavailable."
    return "\(name) \(label): \(qualifier)\(Int(remaining.rounded())) percent remaining.\(reset)"
}

private func compactDuration(until date: Date, now: Date) -> String {
    let totalMinutes = max(0, Int(date.timeIntervalSince(now) / 60))
    let days = totalMinutes / (24 * 60)
    let hours = (totalMinutes % (24 * 60)) / 60
    let minutes = totalMinutes % 60
    // Zero-pad the trailing unit so the column keeps a fixed width and the
    // digits do not jump as the countdown drops (e.g. "6D 04H" vs "5D 09H").
    if days > 0 { return String(format: "%dd %02dh", days, hours) }
    if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
    return String(format: "%02dm", minutes)
}

private func exactTimestamp(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .standard)
}

private struct SessionListView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        if let inspected = model.inspectedSession {
            SessionInspectorView(
                session: inspected,
                reduceMotion: model.reducesMotion,
                back: model.closeInspector,
                focusTerminal: inspected.isDemo ? nil : { model.focusHost(of: inspected) }
            )
            .frame(height: SessionListLayout.inspectorContentHeight - 12, alignment: .top)
            .transition(.opacity)
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        VStack(spacing: 8) {
            if model.sessions.isEmpty {
                Group {
                    if let decision = model.pendingDecision {
                        LiveDecisionView(decision: decision, model: model)
                    } else {
                        EmptySessionView(model: model)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    // The local registry is capped at 40 sessions. Eager rows
                    // avoid SwiftUI's macOS lazy-placement livelock when a
                    // dynamically sized permission row is scrolled after reveal.
                    VStack(spacing: 6) {
                        if let decision = model.pendingDecision {
                            LiveDecisionView(decision: decision, model: model)
                        }
                        ForEach(Array(model.displayedSessions.enumerated()), id: \.element.id) { index, session in
                            SessionRow(
                                session: session,
                                seed: index,
                                reduceMotion: model.reducesMotion,
                                increasedContrast: model.accessibility.increaseContrast,
                                showsMetaLine: model.showsMetaLine(for: session),
                                isSelected: model.selectedSessionID == session.id,
                                contextAttentionAt: model.contextAttentionThreshold,
                                contextCriticalAt: model.contextCriticalThreshold,
                                showsAgents: model.layoutSpec.expandedShowsAgents || model.layoutSpec.showsAgentIndicator,
                                onOpen: session.jumpURL == nil ? nil : { model.open(session) },
                                onInspect: session.isDemo ? nil : { model.inspect(session) },
                                onArchive: session.needsAttention || session.isDemo
                                    ? nil
                                    : { model.archiveSession(session) },
                                onPermissionDecision: { outcome in
                                    model.respondToSessionPermission(
                                        sessionID: session.id,
                                        outcome: outcome
                                    )
                                },
                                onQuestionOption: { label in
                                    model.selectQuestionOption(sessionID: session.id, label: label)
                                },
                                onSubmitQuestion: {
                                    model.submitQuestionSelections(sessionID: session.id)
                                },
                                onAnswerInClaude: {
                                    model.answerQuestionInClaudeCode(sessionID: session.id)
                                },
                                onCustomAnswer: { action in
                                    switch action {
                                    case .begin: model.beginCustomAnswer(sessionID: session.id)
                                    case .cancel: model.cancelCustomAnswer(sessionID: session.id)
                                    case let .submit(text): model.submitCustomAnswer(sessionID: session.id, text: text)
                                    }
                                }
                            )
                        }

                        if model.canRevealAllSessions {
                            Button(action: model.revealAllSessions) {
                                Text(showAllSessionsLabel)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ChimloTheme.mutedPaper)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(
                                "Shows sessions hidden while this question or approval is active"
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var showAllSessionsLabel: String {
        let count = model.sessions.count
        return count == 1 ? "Show all 1 session" : "Show all \(count) sessions"
    }
}

private struct LiveDecisionView: View {
    let decision: ChimloDecisionRequest
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                ClaudeCodeMark(
                    mood: .waiting,
                    size: 38,
                    reduceMotion: model.accessibility.reduceMotion
                )
                VStack(alignment: .leading, spacing: 3) {
                    PixelText(text: "YOUR CALL", pixelSize: 1.2, color: ChimloTheme.attention, spacing: 1)
                    Text(decision.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChimloTheme.paper)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }

            Text(decision.message)
                .font(.system(size: 11))
                .foregroundStyle(ChimloTheme.quietPaper)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button(decision.denyLabel) {
                    model.respondToPendingDecision(approved: false)
                }
                .buttonStyle(ChimloButtonStyle(kind: .destructive, compact: true))
                .keyboardShortcut(.cancelAction)

                Button(decision.approveLabel) {
                    model.respondToPendingDecision(approved: true)
                }
                .buttonStyle(ChimloButtonStyle(kind: .primary, compact: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(11)
        .background(
            model.accessibility.increaseContrast
                ? ChimloTheme.raisedAttentionInk
                : ChimloTheme.attentionInk
        )
        .clipShape(SteppedPanelShape())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Decision needed. \(decision.title). \(decision.message)")
    }
}

struct SessionRow: View {
    let session: SessionDisplayModel
    let seed: Int
    let reduceMotion: Bool
    let increasedContrast: Bool
    var showsMetaLine = false
    var isSelected = false
    var contextAttentionAt = 0.7
    var contextCriticalAt = 0.9
    var showsAgents = true
    var onOpen: (() -> Void)? = nil
    /// Opens the session's activity feed. When set, a click on the row opens
    /// the feed and the jump mark beside the title goes to the terminal.
    var onInspect: (() -> Void)? = nil
    var onArchive: (() -> Void)? = nil
    var onPermissionDecision: ((ProviderPermissionOutcome) -> Void)? = nil
    var onQuestionOption: ((String) -> Void)? = nil
    var onSubmitQuestion: (() -> Void)? = nil
    var onAnswerInClaude: (() -> Void)? = nil
    var onCustomAnswer: ((CustomAnswerAction) -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            summaryCard

            if let permission = session.permission {
                SessionPermissionView(
                    presentation: permission,
                    decide: { onPermissionDecision?($0) }
                )
            }

            if let question = session.question {
                SessionQuestionView(
                    presentation: question,
                    select: { onQuestionOption?($0) },
                    submit: { onSubmitQuestion?() },
                    answerInClaude: { onAnswerInClaude?() },
                    customAnswer: { onCustomAnswer?($0) }
                )
            }

            if session.showsCompletedConversation {
                completionDetails
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var summaryCard: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let onInspect {
                    Button(action: onInspect) {
                        rowContent
                    }
                    .buttonStyle(SessionMessageButtonStyle(
                        isHovering: isHovering
                    ))
                    .accessibilityLabel(accessibilitySummary)
                    .accessibilityHint("Shows this session's activity")
                } else if let onOpen {
                    Button(action: onOpen) {
                        rowContent
                    }
                    .buttonStyle(SessionMessageButtonStyle(
                        isHovering: isHovering
                    ))
                    .accessibilityLabel(accessibilitySummary)
                    .accessibilityHint("Returns to the originating session")
                } else {
                    rowContent
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilitySummary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingAccessory
        }
        .overlayPreferenceValue(JumpMarkAnchorKey.self) { anchor in
            jumpOverlay(anchor)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? ChimloTheme.providerOrange.opacity(0.8)
                        : isHovering ? ChimloTheme.rowHoverEdge : .clear,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            ClaudeCodeMark(
                mood: session.mood,
                size: 34,
                reduceMotion: reduceMotion
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChimloTheme.paper)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if onOpen != nil {
                        // The jump mark is its own button once the row opens
                        // the feed; it sits over the row in `jumpOverlay`.
                        PixelJumpMark(
                            color: isHovering ? ChimloTheme.paper : ChimloTheme.mutedPaper
                        )
                        .fixedSize()
                        .opacity(onInspect == nil ? 1 : 0)
                        .anchorPreference(key: JumpMarkAnchorKey.self, value: .bounds) { $0 }
                    }

                    Spacer(minLength: 6)

                    RunStateBadge(
                        state: session.runState,
                        reduceMotion: reduceMotion,
                        isHovering: isHovering
                    )

                    if let model = session.model, !model.isEmpty {
                        SessionMetadataBadge(
                            text: model,
                            background: neutralBadgeBackground
                        )
                    }

                    if let terminal = session.terminal, !terminal.isEmpty {
                        SessionMetadataBadge(
                            text: terminal,
                            background: neutralBadgeBackground
                        )
                    }
                }
                .padding(.trailing, trailingAccessoryInset)

                if let prompt = session.latestUserPrompt {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("You:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChimloTheme.quietPaper)
                        Text(prompt)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChimloTheme.quietPaper)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if session.isDemo {
                            Text("Preview")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(ChimloTheme.mutedPaper)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(session.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusDetailColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let response = session.latestAgentResponse {
                    Text(response)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusDetailColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if session.latestUserPrompt != nil {
                    Text(session.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusDetailColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showsMetaLine {
                    SessionMetaLine(
                        session: session,
                        attentionAt: contextAttentionAt,
                        criticalAt: contextCriticalAt,
                        showsAgents: showsAgents
                    )
                    .frame(height: SessionMetaLine.height - 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 62)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// A real button at the jump mark's place, above the row's own button,
    /// so one click jumps to the terminal and any other click opens the feed.
    @ViewBuilder
    private func jumpOverlay(_ anchor: Anchor<CGRect>?) -> some View {
        if let onOpen, onInspect != nil, let anchor {
            GeometryReader { geometry in
                let frame = geometry[anchor]
                Button(action: onOpen) {
                    PixelJumpMark(color: isHovering ? ChimloTheme.paper : ChimloTheme.mutedPaper)
                        .frame(width: frame.width + 10, height: frame.height + 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.terminal.map { "Jump to \($0)" } ?? "Jump to the session")
                .accessibilityLabel(session.terminal.map { "Jump to \($0)" } ?? "Jump to the session")
                .position(x: frame.midX, y: frame.midY)
            }
        }
    }

    private var trailingAccessory: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            ZStack {
                SessionTimeBadge(
                    text: SessionRelativeTime.shortLabel(
                        since: session.updatedAt,
                        now: timeline.date
                    ),
                    accessibilityLabel: SessionRelativeTime.accessibilityLabel(
                        since: session.updatedAt,
                        now: timeline.date
                    )
                )
                .opacity(onArchive != nil && isHovering ? 0 : 1)
                .accessibilityHidden(onArchive != nil && isHovering)

                if let onArchive {
                    Button(action: onArchive) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 34, height: 28)
                    }
                    .buttonStyle(SessionArchiveButtonStyle())
                    .help("Archive in Claude Overhead")
                    .accessibilityLabel("Archive \(session.displayTitle) in Claude Overhead")
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
                }
            }
        }
        .frame(width: 34, height: 28)
        .padding(.top, trailingAccessoryTopPadding)
        .padding(.trailing, 6)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private let trailingAccessoryInset: CGFloat = 36

    private var neutralBadgeBackground: Color {
        isHovering ? ChimloTheme.hoveredBadgeInk : ChimloTheme.badgeInk
    }

    private var trailingAccessoryTopPadding: CGFloat {
        let hasConversationPreview = session.latestUserPrompt != nil
            || session.latestAgentResponse != nil
        return hasConversationPreview ? 3 : 9
    }

    private var completionDetails: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("You:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChimloTheme.mutedPaper)

                Text(session.latestUserPrompt ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChimloTheme.selectedInk)

            Text(session.latestAgentResponse ?? "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(ChimloTheme.quietPaper)
                .lineSpacing(2)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(ChimloTheme.raisedInk)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    increasedContrast ? ChimloTheme.quietPaper : ChimloTheme.selectedInk,
                    lineWidth: 1
                )
        }
    }

    private var cardBackground: Color {
        if isHovering { return ChimloTheme.rowHoverInk }

        switch session.mood {
        case .waiting, .question: return ChimloTheme.attentionInk
        case .failed: return ChimloTheme.failureInk
        case .idle, .working, .success: return .clear
        }
    }

    private var statusDetailColor: Color {
        switch session.mood {
        case .waiting, .question: ChimloTheme.attention
        case .failed: ChimloTheme.clayText
        case .idle, .working, .success: ChimloTheme.quietPaper
        }
    }

    private var isClaudeSession: Bool {
        session.agentName.localizedCaseInsensitiveContains("claude")
    }

    private var accessibilitySummary: String {
        let prompt = session.latestUserPrompt.map { "User prompt: \($0)." } ?? ""
        let response = session.latestAgentResponse ?? session.detail
        return "\(session.agentName), \(session.displayTitle), \(session.mood.accessibilityDescription). \(prompt) Latest response: \(response)"
    }
}

private struct SessionPermissionView: View {
    let presentation: SessionPermissionPresentation
    let decide: (ProviderPermissionOutcome) -> Void

    private var request: ProviderPermissionRequest { presentation.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 7) {
                PixelSystemGlyph(
                    kind: .warning,
                    color: ChimloTheme.providerOrange,
                    size: 15
                )

                Text(request.toolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ChimloTheme.providerOrange)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text("Claude permission")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ChimloTheme.mutedPaper)
            }

            Text(request.prompt)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChimloTheme.paper)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = request.detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let preview = request.preview {
                Text(preview)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(ChimloTheme.raisedInk)
                    .clipShape(SteppedPanelShape())
            }

            HStack(spacing: 6) {
                Button("Deny") {
                    decide(.denied)
                }
                .buttonStyle(PermissionActionButtonStyle(kind: .deny))
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Deny this Claude Code tool request")

                Button("Allow Once") {
                    decide(.allowedOnce)
                }
                .buttonStyle(PermissionActionButtonStyle(kind: .once))
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Allow only this Claude Code tool request")

                Button("Allow All") {
                    decide(.allowedForSession)
                }
                .buttonStyle(PermissionActionButtonStyle(kind: .session))
                .accessibilityHint("Allow Claude's matching requests for this session only")
            }
        }
        // The stepped cut removes six points at the top-left. Twelve points of
        // leading padding keeps the icon, type, and buttons fully clear of it.
        .padding(.top, 10)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.bottom, 9)
        .background(ChimloTheme.attentionInk)
        .clipShape(SteppedPanelShape())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Claude Code permission for \(request.toolName). \(request.prompt)"
        )
    }
}

private struct PermissionActionButtonStyle: ButtonStyle {
    enum Kind {
        case deny
        case once
        case session
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 31)
            .background(background(isPressed: configuration.isPressed))
            .clipShape(SteppedPanelShape())
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .deny: ChimloTheme.clayText
        case .once, .session: ChimloTheme.ink
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch kind {
        case .deny:
            isPressed ? ChimloTheme.clay.opacity(0.42) : ChimloTheme.clay.opacity(0.24)
        case .once:
            isPressed ? ChimloTheme.quietPaper : ChimloTheme.paper
        case .session:
            isPressed ? ChimloTheme.attention : ChimloTheme.providerOrange
        }
    }
}

enum CustomAnswerAction {
    case begin
    case cancel
    case submit(String)
}

private struct SessionQuestionView: View {
    let presentation: SessionQuestionPresentation
    let select: (String) -> Void
    let submit: () -> Void
    let answerInClaude: () -> Void
    let customAnswer: (CustomAnswerAction) -> Void
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var question: ProviderQuestion { presentation.question }

    /// Claude Code's own prompt always offers "Other" with free text; this
    /// is the same choice, answered in the notch.
    @ViewBuilder
    private var otherAnswer: some View {
        if presentation.isEnteringCustomAnswer {
            HStack(spacing: 6) {
                TextField("Type your answer", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChimloTheme.paper)
                    .focused($draftFocused)
                    .onSubmit { customAnswer(.submit(draft)) }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(ChimloTheme.raisedAttentionInk)
                    .clipShape(SteppedPanelShape())
                    .accessibilityLabel("Your own answer")
                Button("Send") { customAnswer(.submit(draft)) }
                    .buttonStyle(ChimloButtonStyle(kind: .primary, compact: true))
                    .disabled(!ClaudeQuestionHook.isValidCustomAnswer(draft))
                Button {
                    draft = ""
                    customAnswer(.cancel)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(ProviderFallbackButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel your own answer")
            }
            .onAppear { draftFocused = true }
        } else {
            Button {
                customAnswer(.begin)
            } label: {
                Text("Other…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(QuestionOptionButtonStyle(selected: false))
            .accessibilityHint("Type your own answer instead")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(question.header ?? "Claude asks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChimloTheme.providerOrange)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if presentation.questionCount > 1 {
                    Text("\(presentation.questionIndex + 1) of \(presentation.questionCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ChimloTheme.mutedPaper)
                        .monospacedDigit()
                }
            }

            Text(question.prompt)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChimloTheme.paper)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 5) {
                ForEach(question.options, id: \.label) { option in
                    Button {
                        select(option.label)
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            if question.allowsMultipleSelections {
                                PixelChoiceMark(
                                    selected: presentation.selectedLabels.contains(option.label)
                                )
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(ChimloTheme.paper)
                                    .fixedSize(horizontal: false, vertical: true)

                                if let detail = option.detail {
                                    Text(detail)
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(ChimloTheme.quietPaper)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, option.detail == nil ? 7 : 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(QuestionOptionButtonStyle(
                        selected: presentation.selectedLabels.contains(option.label)
                    ))
                    .accessibilityHint(
                        question.allowsMultipleSelections
                            ? "Toggles this answer"
                            : "Sends this answer to Claude Code"
                    )
                }
                otherAnswer
            }

            HStack(spacing: 10) {
                Button("Answer in Claude Code", action: answerInClaude)
                    .buttonStyle(ProviderFallbackButtonStyle())

                Spacer(minLength: 8)

                if question.allowsMultipleSelections {
                    Button(submitLabel, action: submit)
                        .buttonStyle(ChimloButtonStyle(kind: .primary, compact: true))
                        .disabled(presentation.selectedLabels.isEmpty)
                } else {
                    Text("Choose an option to continue")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ChimloTheme.mutedPaper)
                }
            }
        }
        // The stepped top-left cut is six points. Twelve points of leading
        // padding keeps every glyph and control fully inside the live region.
        .padding(.top, 10)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
        .background(ChimloTheme.attentionInk)
        .clipShape(SteppedPanelShape())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Code asks: \(question.prompt)")
    }

    private var submitLabel: String {
        let count = presentation.selectedLabels.count
        return count == 1 ? "Send 1 answer" : "Send \(count) answers"
    }
}

private struct QuestionOptionButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(background(isPressed: configuration.isPressed))
            .clipShape(SteppedPanelShape())
            .contentShape(Rectangle())
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed { return ChimloTheme.hoveredBadgeInk }
        if selected { return ChimloTheme.raisedAttentionInk }
        return ChimloTheme.raisedInk
    }
}

private struct ProviderFallbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(
                configuration.isPressed ? ChimloTheme.paper : ChimloTheme.quietPaper
            )
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}

private struct PixelChoiceMark: View {
    let selected: Bool

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, _ in
            let unit: CGFloat = 2
            let points = selected
                ? [
                    CGPoint(x: 0, y: 2), CGPoint(x: 1, y: 3), CGPoint(x: 2, y: 2),
                    CGPoint(x: 3, y: 1), CGPoint(x: 4, y: 0),
                ]
                : [
                    CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0),
                    CGPoint(x: 0, y: 4), CGPoint(x: 4, y: 4),
                ]
            for point in points {
                context.fill(
                    Path(CGRect(
                        x: point.x * unit,
                        y: point.y * unit,
                        width: unit,
                        height: unit
                    )),
                    with: .color(selected ? ChimloTheme.attention : ChimloTheme.mutedPaper)
                )
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

private struct SessionArchiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                configuration.isPressed ? ChimloTheme.paper : ChimloTheme.mutedPaper
            )
            .contentShape(Rectangle())
    }
}

private struct SessionMessageButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(background(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed { return ChimloTheme.badgeInk }
        if isHovering { return ChimloTheme.rowHoverInk }
        return .clear
    }
}

private struct SessionMetadataBadge: View {
    let text: String
    var foreground = ChimloTheme.quietPaper
    var background = ChimloTheme.badgeInk

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .frame(height: 18)
            .fixedSize(horizontal: true, vertical: false)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Says in words what the avatar's mood shows: is this Claude working right
/// now, waiting for the owner, or idle until the next prompt?
private struct SessionTimeBadge: View {
    let text: String
    let accessibilityLabel: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ChimloTheme.mutedPaper)
            .lineLimit(1)
            .monospacedDigit()
            .frame(width: 34, height: 18)
            .background(ChimloTheme.badgeInk)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct EmptySessionView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        HStack(spacing: 11) {
            ClaudeCodeMark(mood: .idle, size: 34, reduceMotion: model.accessibility.reduceMotion)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChimloTheme.paper)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(ChimloTheme.raisedSurface(increasedContrast: model.accessibility.increaseContrast))
        .clipShape(SteppedPanelShape())
    }

    private var title: String {
        if model.isScanningSessions { return "Finding local sessions" }
        if model.isReceivingAgentEvents { return "No active sessions" }
        if model.hasInstalledAgent { return "Waiting for the first event" }
        return "Connect Claude Code"
    }

    private var detail: String {
        if model.isScanningSessions { return "Checking Claude sessions and live processes." }
        if model.isReceivingAgentEvents { return "Claude Overhead is live. Start or resume a turn." }
        if model.hasInstalledAgent { return "Send a new prompt in Claude Code." }
        return "Connect Claude Code once to get started."
    }

    @ViewBuilder
    private var action: some View {
        if !model.claudeConnectionState.isInstalled {
            switch model.claudeConnectionState {
            case .disconnected, .needsRepair:
                Button(model.claudeConnectionState == .needsRepair ? "Repair" : "Connect") {
                    model.beginReconnect()
                }
                .buttonStyle(ChimloButtonStyle(kind: .primary, compact: true))
            case .unavailable:
                Button("Retry") { model.refreshAgentConnections() }
                    .buttonStyle(ChimloButtonStyle(kind: .quiet, compact: true))
            case .checking, .installedAwaitingEvent, .receiving:
                EmptyView()
            }
        }
    }
}
