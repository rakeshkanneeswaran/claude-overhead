import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: ApplicationModel

    private var bandHeight: CGFloat {
        max(model.islandLayout.expandedContentTopInset, 36)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingStatusBand(model: model)
                .frame(height: bandHeight)

            Group {
                switch model.onboardingStep {
                case .working:
                    working
                case .permission:
                    permission
                case let .resolving(allowed):
                    resolving(allowed: allowed)
                case let .complete(allowed):
                    complete(allowed: allowed)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Overhead first-run tour")
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            TourStepHeader(marker: "1 / 2", title: "Agent working")

            demoSessionRow

            Text("Claude Overhead shows live agent activity.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChimloTheme.quietPaper)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip tour", action: model.finishOnboarding)
                    .buttonStyle(TourTextButtonStyle())
                Spacer()
                PixelText(text: "DEMO RUNNING", pixelSize: 1, color: ChimloTheme.mutedPaper, spacing: 1)
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 9) {
            TourStepHeader(marker: "2 / 2", title: "Your call")

            demoSessionRow

            HStack(alignment: .top, spacing: 9) {
                PixelSystemGlyph(kind: .warning, color: ChimloTheme.attention, size: 15)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Run project checks")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChimloTheme.paper)
                    Text("swift test --filter LighthouseTests")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChimloTheme.quietPaper)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 9)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChimloTheme.attentionInk)
            .clipShape(SteppedPanelShape())

            HStack(spacing: 8) {
                Button("Deny") { model.resolveDemoPermission(allowed: false) }
                    .buttonStyle(ChimloButtonStyle(kind: .destructive, compact: true))
                    .keyboardShortcut(.cancelAction)

                Spacer(minLength: 8)

                Text("Demo only. Nothing runs.")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(ChimloTheme.mutedPaper)

                Button("Allow once") { model.resolveDemoPermission(allowed: true) }
                    .buttonStyle(ChimloButtonStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func resolving(allowed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TourStepHeader(
                marker: allowed ? "APPROVED" : "DENIED",
                title: allowed ? "Agent continues" : "Agent stopped",
                markerPosition: .trailing,
                markerColor: allowed ? ChimloTheme.moss : ChimloTheme.clayText
            )

            demoSessionRow

            Text(
                allowed
                    ? "Claude Overhead waits for the result."
                    : "Nothing ran."
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ChimloTheme.quietPaper)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func complete(allowed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TourStepHeader(
                marker: "READY",
                title: "That's it. You're ready.",
                markerPosition: .trailing,
                markerColor: ChimloTheme.moss
            )

            demoSessionRow

            Text(
                allowed
                    ? "That was a preview. Your Claude sessions will now stay within reach, right here."
                    : "That was a preview, and nothing ran. Your real Claude sessions will show up right here."
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ChimloTheme.quietPaper)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Explore features") {
                    model.finishOnboarding()
                    model.openPanel()
                }
                .buttonStyle(TourTextButtonStyle())
                Spacer(minLength: 8)
                Button("Start using Overhead", action: model.finishOnboarding)
                    .buttonStyle(ChimloButtonStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var demoSessionRow: some View {
        if let session = model.onboardingSession {
            SessionRow(
                session: session,
                seed: 0,
                reduceMotion: model.accessibility.reduceMotion,
                increasedContrast: model.accessibility.increaseContrast
            )
        }
    }
}

private struct OnboardingStatusBand: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        GeometryReader { geometry in
            if model.islandLayout.hasCameraHousing {
                let cameraWidth = min(
                    model.islandLayout.cameraHousingWidth,
                    geometry.size.width
                )
                let wingWidth = max(0, (geometry.size.width - cameraWidth) / 2)

                HStack(spacing: 0) {
                    brand
                        .padding(.leading, 16)
                        .frame(width: wingWidth, height: geometry.size.height, alignment: .leading)
                        .clipped()

                    Color.clear
                        .frame(width: cameraWidth, height: geometry.size.height)
                        .accessibilityHidden(true)

                    status
                        .padding(.trailing, 16)
                        .frame(width: wingWidth, height: geometry.size.height, alignment: .trailing)
                        .clipped()
                }
            } else {
                HStack(spacing: 0) {
                    brand
                    Spacer(minLength: 20)
                    status
                }
                .padding(.horizontal, 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Overhead is \(statusLabel.lowercased())")
    }

    private var brand: some View {
        PixelText(text: "OVERHEAD", pixelSize: 1.1, color: ChimloTheme.paper, spacing: 1)
    }

    private var status: some View {
        HStack(spacing: 5) {
            PixelAvatar(
                mood: statusMood,
                seed: 7,
                size: 20,
                reduceMotion: model.accessibility.reduceMotion
            )
            PixelText(text: statusLabel, pixelSize: 1, color: statusColor, spacing: 1)
        }
    }

    private var statusMood: AvatarMood {
        switch model.onboardingStep {
        case .working: .working
        case .permission: .waiting
        case let .resolving(allowed): allowed ? .working : .idle
        case let .complete(allowed): allowed ? .success : .idle
        }
    }

    private var statusLabel: String {
        switch model.onboardingStep {
        case .working: "WORK"
        case .permission: "WAIT"
        case let .resolving(allowed): allowed ? "WORK" : "STOP"
        case let .complete(allowed): allowed ? "DONE" : "SAFE"
        }
    }

    private var statusColor: Color {
        switch model.onboardingStep {
        case .working, .permission:
            ChimloTheme.attention
        case .complete(true):
            ChimloTheme.moss
        case .resolving, .complete(false):
            ChimloTheme.paper
        }
    }
}

private struct TourStepHeader: View {
    enum MarkerPosition {
        case leading
        case trailing
    }

    let marker: String
    let title: String
    var markerPosition: MarkerPosition = .leading
    var markerColor: Color = ChimloTheme.mutedPaper

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if markerPosition == .leading {
                markerLabel
            }

            Text(title)
                .font(.system(size: 15, weight: .bold))
                .tracking(-0.1)
                .foregroundStyle(ChimloTheme.paper)

            Spacer(minLength: 0)

            if markerPosition == .trailing {
                markerLabel
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var markerLabel: some View {
        PixelText(text: marker, pixelSize: 1, color: markerColor, spacing: 1)
    }
}

private struct TourTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(
                configuration.isPressed ? ChimloTheme.paper : ChimloTheme.mutedPaper
            )
            .padding(.horizontal, 2)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
    }
}
