import AppKit
import ChimloCore
import SwiftUI

// MARK: Design system

enum SetupTheme {
    static let canvas = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let raised = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.09)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.4)
    static let accent = ChimloTheme.providerOrange
    static let success = ChimloTheme.liveGreen
    static let danger = ChimloTheme.clayText
}

enum SetupLayout {
    static let windowSize = CGSize(width: 780, height: 600)
    static let gutter: CGFloat = 48
    static let visualHeight: CGFloat = 210
}

enum SetupMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Moving between screens.
    static var screen: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.88)
    }

    /// A change inside a screen: a stage finishing, a card appearing.
    static var state: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.9)
    }
}

struct SetupPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .frame(minWidth: 132, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SetupTheme.accent.opacity(isHovering && isEnabled ? 1 : 0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: SetupTheme.accent.opacity(isEnabled ? 0.32 : 0), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }
}

struct SetupSecondaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isHovering ? SetupTheme.textPrimary : SetupTheme.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.07 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private struct SetupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SetupTheme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SetupTheme.hairline, lineWidth: 1)
            )
    }
}

private struct SetupHeadline: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.5)
                .foregroundStyle(SetupTheme.textPrimary)
                .frame(maxWidth: 680)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(SetupTheme.textSecondary)
                .lineSpacing(2.5)
                .frame(maxWidth: 540)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The frame every screen shares: a visual, the headline, the screen's own
/// content, and a footer with Back on the left and the actions on the right.
private struct SetupScreen<Visual: View, Content: View, Footer: View>: View {
    var visualHeight: CGFloat = SetupLayout.visualHeight
    @ViewBuilder let visual: () -> Visual
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            // Equal flexible space above and below keeps each screen's block
            // centred between the title bar and the footer.
            Spacer(minLength: 36)
            visual()
                .frame(height: visualHeight)
            SetupHeadline(title: title, subtitle: subtitle)
                .padding(.top, 26)
            content()
                .padding(.top, 22)
            Spacer(minLength: 20)
            HStack(spacing: 10) { footer() }
                .padding(.bottom, 28)
        }
        .padding(.horizontal, SetupLayout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Deep graphite with a warm light from above, the only decoration.
private struct SetupBackdrop: View {
    var body: some View {
        ZStack {
            SetupTheme.canvas
            RadialGradient(
                colors: [SetupTheme.accent.opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: -0.08),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: Window

struct SetupWindowView: View {
    @ObservedObject var setup: SetupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SetupBackdrop()
            screen
                .id(screenKey)
                .transition(screenTransition)
        }
        .frame(width: SetupLayout.windowSize.width, height: SetupLayout.windowSize.height)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var screen: some View {
        switch setup.flow.step {
        case .welcome:
            WelcomeScreen(setup: setup, reduceMotion: reduceMotion)
        case .findClaudeCode:
            FindClaudeCodeScreen(setup: setup)
        case .explain:
            ExplainScreen(setup: setup)
        case .connecting, .failed:
            ConnectingScreen(setup: setup, reduceMotion: reduceMotion)
        case .connected:
            ConnectedScreen(setup: setup, reduceMotion: reduceMotion)
        }
    }

    /// Connecting and failing share one screen, so a failure lands in place
    /// next to the stage it happened in instead of on a new page.
    private var screenKey: String {
        switch setup.flow.step {
        case .welcome: "welcome"
        case .findClaudeCode: "find"
        case .explain: "explain"
        case .connecting, .failed: "connect"
        case .connected: "connected"
        }
    }

    private var screenTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 28)),
                removal: .opacity.combined(with: .offset(x: -28))
            )
    }
}

// MARK: Screen 1: welcome

private struct WelcomeScreen: View {
    @ObservedObject var setup: SetupCoordinator
    let reduceMotion: Bool

    var body: some View {
        SetupScreen(
            visualHeight: 220,
            visual: { NotchStoryboard(reduceMotion: reduceMotion) },
            title: "Your Claude Code. Always in sight.",
            subtitle: "Meet your notch companion. Stay connected to Claude Code, see what it's doing, and know exactly when it needs you.",
            content: { EmptyView() },
            footer: {
                Spacer()
                if setup.flow.integrationInstalled {
                    Button("Already connected? Check it", action: setup.connect)
                        .buttonStyle(SetupSecondaryButtonStyle())
                }
                Button("Get started", action: setup.getStarted)
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
        )
    }
}

// MARK: Screen 2: find Claude Code

private struct FindClaudeCodeScreen: View {
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        SetupScreen(
            visualHeight: 120,
            visual: { DetectionBadge(detection: setup.flow.detection) },
            title: detectionTitle,
            subtitle: "Claude Overhead works alongside Claude Code to keep you updated on your coding sessions.",
            content: { detectionCard.frame(maxWidth: 520) },
            footer: {
                Button("Back", action: setup.back)
                    .buttonStyle(SetupSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                actions
            }
        )
    }

    private var detectionTitle: String {
        if case .notFound = setup.flow.detection { return "Claude Code isn't installed yet." }
        return "Let's connect Claude Code."
    }

    @ViewBuilder
    private var detectionCard: some View {
        switch setup.flow.detection {
        case .checking:
            SetupCard {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Claude Code on this Mac…")
                        .font(.system(size: 13.5))
                        .foregroundStyle(SetupTheme.textSecondary)
                }
            }
        case let .found(installation):
            SetupCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(SetupTheme.success)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Claude Code")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SetupTheme.textPrimary)
                        Text("Installed and ready to connect.")
                            .font(.system(size: 13))
                            .foregroundStyle(SetupTheme.textSecondary)
                        Text("\(installation.summary) · \(abbreviated(installation.path))")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(SetupTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.top, 2)
                    }
                }
            }
        case .notFound:
            SetupCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Claude Overhead needs Claude Code first. Install it from the official guide, then check again. It works with the command line, the VS Code and JetBrains extensions, and the Desktop app.")
                        .font(.system(size: 13))
                        .foregroundStyle(SetupTheme.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open the install guide", action: setup.openInstallGuide)
                        .buttonStyle(SetupSecondaryButtonStyle())
                }
            }
        case let .failed(reason):
            SetupCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(ChimloTheme.attention)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Claude Code's settings need attention")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SetupTheme.textPrimary)
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundStyle(SetupTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch setup.flow.detection {
        case .checking:
            Button("Connect Claude Code") {}
                .buttonStyle(SetupPrimaryButtonStyle())
                .disabled(true)
        case .found:
            Button("Connect Claude Code", action: setup.continueToExplain)
                .buttonStyle(SetupPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .notFound:
            Button("Set up later", action: setup.notNow)
                .buttonStyle(SetupSecondaryButtonStyle())
            Button("Check again", action: setup.detectClaudeCode)
                .buttonStyle(SetupPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Check again", action: setup.detectClaudeCode)
                .buttonStyle(SetupPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct DetectionBadge: View {
    let detection: SetupFlow.Detection

    var body: some View {
        ZStack {
            Circle()
                .fill(SetupTheme.raised)
                .overlay(Circle().strokeBorder(ringColor, lineWidth: 1.5))
                .frame(width: 92, height: 92)
            Image(systemName: "terminal.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(SetupTheme.textPrimary)
            badge
                .offset(x: 32, y: 32)
                .transition(.scale.combined(with: .opacity))
        }
        .accessibilityHidden(true)
    }

    private var ringColor: Color {
        switch detection {
        case .found: SetupTheme.success.opacity(0.7)
        case .failed: ChimloTheme.attention.opacity(0.7)
        case .checking, .notFound: SetupTheme.hairline
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch detection {
        case .checking:
            ProgressView().controlSize(.small)
        case .found:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(SetupTheme.success, SetupTheme.canvas)
        case .notFound:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(SetupTheme.textTertiary, SetupTheme.canvas)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(ChimloTheme.attention, SetupTheme.canvas)
        }
    }
}

// MARK: Screen 3: what connecting does

private struct ExplainScreen: View {
    @ObservedObject var setup: SetupCoordinator
    @State private var showsChanges = false

    var body: some View {
        SetupScreen(
            visualHeight: 118,
            visual: { benefits },
            title: "One small connection. A much better experience.",
            subtitle: "Overhead adds a small set of hooks to Claude Code, so it can understand session activity and show you what matters.",
            content: {
                VStack(spacing: 14) {
                    if setup.flow.integrationNeedsRepair {
                        Label("Overhead's hooks were changed or moved. Connecting repairs them.", systemImage: "wrench.and.screwdriver.fill")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(ChimloTheme.attention)
                    }
                    changesButton
                    privacy
                }
                .frame(maxWidth: 560)
            },
            footer: {
                Button("Back", action: setup.back)
                    .buttonStyle(SetupSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Not now", action: setup.notNow)
                    .buttonStyle(SetupSecondaryButtonStyle())
                Button(setup.flow.integrationNeedsRepair ? "Repair" : "Connect", action: setup.connect)
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        )
    }

    private var benefits: some View {
        HStack(spacing: 12) {
            BenefitTile(symbol: "dot.radiowaves.left.and.right", title: "Session awareness", detail: "See every session working, waiting, or idle.")
            BenefitTile(symbol: "hand.raised.fill", title: "Answer in place", detail: "Approve tools and answer Claude's questions from the notch.")
            BenefitTile(symbol: "sparkles", title: "Know when it's done", detail: "A glow when Claude replies, and your usage at a glance.")
        }
        .frame(maxWidth: 640)
    }

    /// The details open in a popover beside the button, so the screen stays
    /// short and calm while every fact stays one click away.
    private var changesButton: some View {
        Button {
            showsChanges = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(SetupTheme.accent)
                Text("What changes on my Mac?")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SetupTheme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SetupTheme.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SetupTheme.raised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SetupTheme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsChanges, arrowEdge: .bottom) {
            ChangesPopover(setup: setup)
        }
    }

    private var privacy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(SetupTheme.textTertiary)
                .padding(.top, 2)
            Text("Your coding sessions stay on your Mac. Overhead doesn't upload transcripts, prompts, or source code, and it has no analytics.")
                .font(.system(size: 12.5))
                .foregroundStyle(SetupTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

private struct ChangesPopover: View {
    @ObservedObject var setup: SetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What connecting changes")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(SetupTheme.textPrimary)
            ChangeLine("Adds Overhead's hooks to ~/.claude/settings.json. Your other settings and hooks stay exactly as they are.")
            ChangeLine("Saves a one-time copy of your original file as settings.json.overhead-backup before the first change.")
            ChangeLine("Routes the status line through a small bridge that keeps any status line you already have.")
            ChangeLine("Installs a small helper in ~/Library/Application Support/Overhead.")
            ChangeLine("Disconnect any time in Settings → Agents. Only Overhead's own entries are removed.")

            if let preview = setup.settingsPreview {
                ScrollView {
                    Text(preview)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SetupTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
                Button("Hide the exact settings", action: setup.hideSettingsPreview)
                    .buttonStyle(SetupSecondaryButtonStyle())
            } else {
                Button("Show the exact settings", action: setup.showSettingsPreview)
                    .buttonStyle(SetupSecondaryButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 440)
        .environment(\.colorScheme, .dark)
    }
}

private struct BenefitTile: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SetupTheme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SetupTheme.accent.opacity(0.13)))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SetupTheme.textPrimary)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(SetupTheme.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SetupTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SetupTheme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct ChangeLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(SetupTheme.textTertiary).frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(SetupTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Screen 4: connecting, or why it stopped

private struct ConnectingScreen: View {
    @ObservedObject var setup: SetupCoordinator
    let reduceMotion: Bool
    @State private var showsDetails = false

    private var failure: SetupFailure? {
        if case let .failed(failure) = setup.flow.step { return failure }
        return nil
    }

    private var current: SetupStage? {
        if case let .connecting(stage) = setup.flow.step { return stage }
        return nil
    }

    var body: some View {
        SetupScreen(
            visualHeight: 130,
            visual: { ConnectionDiagram(phase: diagramPhase, reduceMotion: reduceMotion).frame(maxHeight: .infinity) },
            title: failure == nil ? "Connecting Claude Code…" : "That didn't work.",
            subtitle: failure?.message ?? "This takes a moment. Nothing leaves your Mac.",
            content: {
                VStack(spacing: 12) {
                    stageList
                    if let failure { details(failure) }
                }
                .frame(maxWidth: 520)
            },
            footer: {
                if failure != nil {
                    Button("Back", action: setup.back)
                        .buttonStyle(SetupSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Not now", action: setup.notNow)
                        .buttonStyle(SetupSecondaryButtonStyle())
                    Button("Try again", action: setup.connect)
                        .buttonStyle(SetupPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Text("Working…")
                        .font(.system(size: 12))
                        .foregroundStyle(SetupTheme.textTertiary)
                        .frame(minHeight: 36)
                    Spacer()
                }
            }
        )
    }

    private var diagramPhase: ConnectionDiagram.Phase {
        if let failure { return .failed(failure.stage) }
        return .connecting(current ?? .checkingClaudeCode)
    }

    private var stageList: some View {
        SetupCard {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(SetupStage.allCases, id: \.self) { stage in
                    StageRow(stage: stage, state: state(of: stage), result: setup.flow.stageResults[stage])
                }
            }
        }
    }

    private func state(of stage: SetupStage) -> StageRow.State {
        if let failure {
            if stage == failure.stage { return .failed }
            return setup.flow.stageResults[stage] == nil ? .pending : .done
        }
        if setup.flow.stageResults[stage] != nil { return .done }
        return stage == current ? .running : .pending
    }

    private func details(_ failure: SetupFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(SetupMotion.state) { showsDetails.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text("Details")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(SetupTheme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")

            if showsDetails {
                Text(failure.details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SetupTheme.textSecondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StageRow: View {
    enum State {
        case pending
        case running
        case done
        case failed
    }

    let stage: SetupStage
    let state: State
    let result: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title)
                    .font(.system(size: 13.5, weight: state == .running ? .semibold : .regular))
                    .foregroundStyle(state == .pending ? SetupTheme.textTertiary : SetupTheme.textPrimary)
                if let result, state == .done {
                    Text(result)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Circle().strokeBorder(SetupTheme.hairline, lineWidth: 1.5)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(SetupTheme.success)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(SetupTheme.danger)
        }
    }

    private var accessibilityState: String {
        switch state {
        case .pending: "Waiting"
        case .running: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

// MARK: Screen 5: connected

private struct ConnectedScreen: View {
    @ObservedObject var setup: SetupCoordinator
    let reduceMotion: Bool
    @State private var revealed = false

    var body: some View {
        SetupScreen(
            visualHeight: 150,
            visual: { notch },
            title: "You're connected.",
            subtitle: "Claude Overhead is ready to work alongside Claude Code.",
            content: {
                SetupCard {
                    VStack(alignment: .leading, spacing: 11) {
                        CheckLine(title: "Claude Code detected", detail: setup.flow.stageResults[.checkingClaudeCode])
                        CheckLine(title: "Overhead integration installed", detail: setup.flow.stageResults[.updatingSettings])
                        CheckLine(title: "Connection verified", detail: setup.flow.stageResults[.verifying])
                    }
                }
                .frame(maxWidth: 520)
            },
            footer: {
                Spacer()
                Button("See your notch", action: setup.seeYourNotch)
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Spacer()
            }
        )
    }

    /// The connection resolves into the real notch, finishing with the same
    /// colour wave Claude Overhead plays when Claude replies.
    private var notch: some View {
        ZStack {
            Circle()
                .fill(SetupTheme.success.opacity(revealed ? 0.12 : 0))
                .frame(width: 220, height: 220)
                .blur(radius: 40)
            MiniNotch(state: .done, reduceMotion: reduceMotion)
                .scaleEffect(revealed ? 1.35 : 0.9)
                .opacity(revealed ? 1 : 0)
        }
        .accessibilityLabel("Your notch, connected")
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.72)) {
                revealed = true
            }
        }
    }
}

private struct CheckLine: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: detail == nil ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(detail == nil ? SetupTheme.textTertiary : SetupTheme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(SetupTheme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
