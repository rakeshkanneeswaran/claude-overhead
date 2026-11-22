import Foundation

/// How tightly session rows pack in the expanded panel.
public enum RowDensity: String, Codable, Sendable, CaseIterable {
    case comfortable
    case compact
}

/// A global multiplier on motion, separate from the layout's own scale, so a
/// user can calm every layout at once.
public enum AnimationIntensity: String, Codable, Sendable, CaseIterable {
    case full
    case reduced
    case minimal

    public var scale: Double {
        switch self {
        case .full: 1
        case .reduced: 0.5
        case .minimal: 0.15
        }
    }
}

/// What a layout shows, as data. The notch view reads this instead of
/// switching on the layout, so each layout is a real difference in content
/// and behaviour, and the differences are testable without SwiftUI.
public struct NotchLayoutSpec: Equatable, Sendable {
    public let showsAvatar: Bool
    public let showsActivityLabel: Bool
    public let showsContextIndicator: Bool
    public let showsAgentIndicator: Bool
    public let showsAttentionSignal: Bool
    /// Width of the compact wings beside the notch, 0.8...1.6; 1 is classic.
    public let compactWingWidthScale: Double
    public let expandedShowsUsage: Bool
    public let expandedShowsAgents: Bool
    public let expandedRowDensity: RowDensity
    /// False means the panel opens only on click.
    public let expandsOnHover: Bool
    /// Motion multiplier, 0...1, applied on top of `AnimationIntensity`.
    public let animationScale: Double

    public static let wingWidthRange: ClosedRange<Double> = 0.8...1.6

    public init(
        showsAvatar: Bool,
        showsActivityLabel: Bool,
        showsContextIndicator: Bool,
        showsAgentIndicator: Bool,
        showsAttentionSignal: Bool,
        compactWingWidthScale: Double,
        expandedShowsUsage: Bool,
        expandedShowsAgents: Bool,
        expandedRowDensity: RowDensity,
        expandsOnHover: Bool,
        animationScale: Double
    ) {
        self.showsAvatar = showsAvatar
        self.showsActivityLabel = showsActivityLabel
        self.showsContextIndicator = showsContextIndicator
        self.showsAgentIndicator = showsAgentIndicator
        self.showsAttentionSignal = showsAttentionSignal
        self.compactWingWidthScale = Self.clamp(compactWingWidthScale, to: Self.wingWidthRange, fallback: 1)
        self.expandedShowsUsage = expandedShowsUsage
        self.expandedShowsAgents = expandedShowsAgents
        self.expandedRowDensity = expandedRowDensity
        self.expandsOnHover = expandsOnHover
        self.animationScale = Self.clamp(animationScale, to: 0...1, fallback: 1)
    }

    /// A copy with selected fields replaced, used to apply user settings.
    func with(
        showsActivityLabel: Bool? = nil,
        showsAgentIndicator: Bool? = nil,
        expandedShowsAgents: Bool? = nil,
        expandedRowDensity: RowDensity? = nil,
        animationScale: Double? = nil
    ) -> NotchLayoutSpec {
        NotchLayoutSpec(
            showsAvatar: showsAvatar,
            showsActivityLabel: showsActivityLabel ?? self.showsActivityLabel,
            showsContextIndicator: showsContextIndicator,
            showsAgentIndicator: showsAgentIndicator ?? self.showsAgentIndicator,
            showsAttentionSignal: showsAttentionSignal,
            compactWingWidthScale: compactWingWidthScale,
            expandedShowsUsage: expandedShowsUsage,
            expandedShowsAgents: expandedShowsAgents ?? self.expandedShowsAgents,
            expandedRowDensity: expandedRowDensity ?? self.expandedRowDensity,
            expandsOnHover: expandsOnHover,
            animationScale: animationScale ?? self.animationScale
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The notch presentations a user can pick.
public enum NotchLayout: String, Codable, Sendable, CaseIterable, Identifiable {
    case minimal
    case classic
    case expanded
    case focus
    case agentView

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimal: "Minimal"
        case .classic: "Classic"
        case .expanded: "Expanded"
        case .focus: "Focus"
        case .agentView: "Agent View"
        }
    }

    public var summary: String {
        switch self {
        case .minimal: "Just Claude and a signal when it needs you, in narrow wings."
        case .classic: "Claude, what it is doing, and a signal when it needs you."
        case .expanded: "Everything at a glance: activity, context, agents and usage."
        case .focus: "Stays still and quiet. Only a signal when Claude needs you; click to open."
        case .agentView: "Built around subagents: see each one and what it is doing."
        }
    }

    public var spec: NotchLayoutSpec {
        switch self {
        case .minimal:
            NotchLayoutSpec(
                showsAvatar: true,
                showsActivityLabel: false,
                showsContextIndicator: false,
                showsAgentIndicator: false,
                showsAttentionSignal: true,
                compactWingWidthScale: 0.8,
                expandedShowsUsage: false,
                expandedShowsAgents: false,
                expandedRowDensity: .comfortable,
                expandsOnHover: true,
                animationScale: 0.7
            )
        case .classic:
            NotchLayoutSpec(
                showsAvatar: true,
                showsActivityLabel: true,
                showsContextIndicator: false,
                showsAgentIndicator: false,
                showsAttentionSignal: true,
                compactWingWidthScale: 1,
                expandedShowsUsage: true,
                expandedShowsAgents: false,
                expandedRowDensity: .comfortable,
                expandsOnHover: true,
                animationScale: 1
            )
        case .expanded:
            NotchLayoutSpec(
                showsAvatar: true,
                showsActivityLabel: true,
                showsContextIndicator: true,
                showsAgentIndicator: true,
                showsAttentionSignal: true,
                compactWingWidthScale: 1.4,
                expandedShowsUsage: true,
                expandedShowsAgents: true,
                expandedRowDensity: .comfortable,
                expandsOnHover: true,
                animationScale: 1
            )
        case .focus:
            // Nothing moves and nothing opens by accident: hover expansion and
            // motion are exactly what breaks concentration.
            NotchLayoutSpec(
                showsAvatar: false,
                showsActivityLabel: false,
                showsContextIndicator: false,
                showsAgentIndicator: false,
                showsAttentionSignal: true,
                compactWingWidthScale: 0.8,
                expandedShowsUsage: false,
                expandedShowsAgents: false,
                expandedRowDensity: .comfortable,
                expandsOnHover: false,
                animationScale: 0.2
            )
        case .agentView:
            NotchLayoutSpec(
                showsAvatar: true,
                showsActivityLabel: true,
                showsContextIndicator: false,
                showsAgentIndicator: true,
                showsAttentionSignal: true,
                compactWingWidthScale: 1.2,
                expandedShowsUsage: false,
                expandedShowsAgents: true,
                expandedRowDensity: .compact,
                expandsOnHover: true,
                animationScale: 1
            )
        }
    }
}
