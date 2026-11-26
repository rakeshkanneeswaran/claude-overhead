import Foundation

public struct IslandDisplayMetrics: Equatable, Sendable {
    public let screenWidth: CGFloat
    public let screenHeight: CGFloat
    public let visibleTop: CGFloat
    public let safeTopInset: CGFloat
    public let cameraHousingLeftEdge: CGFloat?
    public let cameraHousingRightEdge: CGFloat?
    /// The menu bar's height on this display (0 while it is hidden).
    public let menuBarHeight: CGFloat

    public init(
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        visibleTop: CGFloat,
        safeTopInset: CGFloat,
        cameraHousingLeftEdge: CGFloat?,
        cameraHousingRightEdge: CGFloat?,
        menuBarHeight: CGFloat = 24
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.visibleTop = visibleTop
        self.safeTopInset = safeTopInset
        self.cameraHousingLeftEdge = cameraHousingLeftEdge
        self.cameraHousingRightEdge = cameraHousingRightEdge
        self.menuBarHeight = menuBarHeight
    }

    public var cameraHousingWidth: CGFloat {
        guard let left = cameraHousingLeftEdge, let right = cameraHousingRightEdge else { return 0 }
        return Swift.max(0, right - left)
    }

    public var hasCameraHousing: Bool {
        safeTopInset > 0 && cameraHousingWidth > 0
    }
}

public struct IslandLayout: Equatable, Sendable {
    public let compactWidth: CGFloat
    public let compactHeight: CGFloat
    public let expandedWidth: CGFloat
    public let expandedContentTopInset: CGFloat
    public let expandedNeckWidth: CGFloat
    public let cameraHousingWidth: CGFloat
    public let activityWingWidth: CGFloat
    public let hasCameraHousing: Bool
    /// The hidden notch (`NotchVisibilityPolicy`): exactly the camera
    /// housing. A display without one gets an invisible target of the same
    /// width at the top of the screen, where a notch would be.
    public let concealedWidth: CGFloat
    public let concealedHeight: CGFloat

    /// `wingWidthScale` widens the compact activity wings for layouts that
    /// show more than the avatar and a signal (1 = the classic 32-point wings).
    public static func make(
        for display: IslandDisplayMetrics,
        expandedWidthFraction: CGFloat = 0.3,
        wingWidthScale: CGFloat = 1
    ) -> IslandLayout {
        let expandedWidth = display.screenWidth > 0
            ? display.screenWidth * expandedWidthFraction
            : 404

        guard display.hasCameraHousing else {
            return IslandLayout(
                compactWidth: 198,
                compactHeight: 42,
                expandedWidth: max(198, expandedWidth),
                expandedContentTopInset: 0,
                expandedNeckWidth: 198,
                cameraHousingWidth: 0,
                activityWingWidth: 0,
                hasCameraHousing: false,
                concealedWidth: 198,
                concealedHeight: max(22, display.menuBarHeight)
            )
        }

        // The physical camera housing occupies the middle of this window. Claude Overhead
        // paints one interactive activity wing on either side, then grows from
        // that exact silhouette below the hardware when expanded.
        let activityWingWidth = (32 * min(max(wingWidthScale, 0.8), 1.8)).rounded()
        let neckWidth = min(expandedWidth, display.cameraHousingWidth + activityWingWidth * 2)
        return IslandLayout(
            compactWidth: neckWidth,
            compactHeight: display.safeTopInset,
            expandedWidth: max(neckWidth, expandedWidth),
            expandedContentTopInset: display.safeTopInset,
            expandedNeckWidth: neckWidth,
            cameraHousingWidth: display.cameraHousingWidth,
            activityWingWidth: activityWingWidth,
            hasCameraHousing: true,
            concealedWidth: display.cameraHousingWidth,
            concealedHeight: display.safeTopInset
        )
    }
}

public struct ExpandedIslandSilhouette: Equatable, Sendable {
    public let topLeftX: CGFloat
    public let topRightX: CGFloat
    public let topY: CGFloat

    public init(width: CGFloat) {
        topLeftX = 0
        topRightX = max(0, width)
        topY = 0
    }
}

public enum IslandCollapsePolicy {
    public static let hoverDelayMilliseconds = 500
    public static let completionGlowSeconds: TimeInterval = 2.5
    public static let completionGlowFadeSeconds: TimeInterval = 0.8
    public static let completionDetailLifetimeSeconds: TimeInterval = 120

    public static func shouldCollapse(
        pointerInside: Bool,
        isSessionPanel: Bool,
        hasBlockingDecision: Bool
    ) -> Bool {
        !pointerInside && isSessionPanel && !hasBlockingDecision
    }

    public static func isNewCompletion(
        wasArmedForCompletion: Bool,
        eventKind: AgentEventKind
    ) -> Bool {
        eventKind == .completed && wasArmedForCompletion
    }
}
