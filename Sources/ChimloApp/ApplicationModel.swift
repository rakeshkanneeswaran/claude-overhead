import AppKit
import ChimloCore
import ChimloProtocol
import Combine
import Foundation
import SwiftUI

struct SessionDisplayModel: Identifiable, Equatable, Sendable {
    let id: String
    var agentName: String
    var title: String
    var detail: String
    var mood: AvatarMood
    var isDemo: Bool
    var needsAttention: Bool
    var terminal: String?
    var projectPath: String?
    var jumpURL: URL?
    var model: String?
    var updatedAt: Date
    var latestUserPrompt: String?
    var latestAgentResponse: String?
    var latestResponseReceivedAt: Date?
    var permission: SessionPermissionPresentation?
    var question: SessionQuestionPresentation?
    /// Context, cache, agents, branch, PRs and cost from the session file.
    var insights: TranscriptInsights?
    /// Claude Code's own live listing, when it knows this session.
    var live: ClaudeLiveSession?

    var hasActiveOwnerInteraction: Bool {
        permission != nil || question != nil
    }

    var displayTitle: String {
        guard let projectPath else { return title }
        let workspace = URL(fileURLWithPath: projectPath).lastPathComponent
        guard !workspace.isEmpty,
              title.localizedCaseInsensitiveCompare(workspace) != .orderedSame,
              !title.localizedCaseInsensitiveContains("\(workspace) ·") else {
            return title
        }
        return "\(workspace) · \(title)"
    }

    var showsCompletedConversation: Bool {
        guard let latestResponseReceivedAt else { return false }
        return mood == .success
            && latestUserPrompt != nil
            && latestAgentResponse != nil
            && latestResponseReceivedAt >= Date.now.addingTimeInterval(
                -IslandCollapsePolicy.completionDetailLifetimeSeconds
            )
    }

    /// The row's height in the panel. The meta line (branch, context, agents)
    /// sits under the conversation preview and adds one short line.
    func preferredRowHeight(responseTextWidth: CGFloat, includesMetaLine: Bool = false) -> CGFloat {
        let base = baseRowHeight(responseTextWidth: responseTextWidth)
        guard includesMetaLine else { return base }
        // Rows without a prompt line are held at their 62-point minimum,
        // which absorbs most of the extra line.
        return base + (latestUserPrompt != nil ? SessionMetaLineMetrics.height + 1 : 4)
    }

    private func baseRowHeight(responseTextWidth: CGFloat) -> CGFloat {
        if let permission {
            let request = permission.request
            let promptLineCount = measuredLineCount(
                request.prompt,
                font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                width: responseTextWidth
            )
            let detailLineCount = request.detail.map {
                measuredLineCount(
                    $0,
                    font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    width: responseTextWidth
                )
            }
            let previewLineCount = request.preview.map {
                measuredLineCount(
                    $0,
                    font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
                    width: max(1, responseTextWidth - 18)
                )
            }
            return SessionInteractionLayout.permissionRowHeight(
                promptLineCount: promptLineCount,
                detailLineCount: detailLineCount,
                previewLineCount: previewLineCount
            )
        }
        if let question {
            let optionHeight = question.question.options.reduce(CGFloat.zero) { height, option in
                height + (option.detail == nil ? 34 : 50)
            }
            let selectionFooter: CGFloat = question.question.allowsMultipleSelections ? 36 : 20
            let customAnswer: CGFloat = question.isEnteringCustomAnswer ? 66 : 34
            return 70 + 50 + optionHeight + customAnswer + selectionFooter
        }
        guard showsCompletedConversation,
              let latestUserPrompt,
              let latestAgentResponse else { return 70 }

        let promptFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let promptLabelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let promptFixedWidth = ("You:" as NSString).size(withAttributes: [.font: promptLabelFont]).width
            + 6
        let promptTextWidth = max(1, responseTextWidth - promptFixedWidth)
        let promptLineHeight = ceil(promptFont.ascender - promptFont.descender + promptFont.leading)
        let promptLineCount = measuredLineCount(
            latestUserPrompt,
            font: promptFont,
            width: promptTextWidth,
            maximum: 2
        )
        let promptHeight = CGFloat(promptLineCount) * promptLineHeight + 20

        let responseFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let responseLineHeight = ceil(
            responseFont.ascender - responseFont.descender + responseFont.leading
        )
        let responseLineCount = measuredLineCount(
            latestAgentResponse,
            font: responseFont,
            width: responseTextWidth,
            maximum: 6
        )
        let responseHeight = CGFloat(responseLineCount) * responseLineHeight
            + CGFloat(responseLineCount - 1) * 2
            + 20

        return 70 + 8 + promptHeight + responseHeight
    }

    private func measuredLineCount(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        maximum: Int? = nil
    ) -> Int {
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let measured = max(1, Int(ceil(bounds.height / lineHeight)))
        return maximum.map { min($0, measured) } ?? measured
    }
}

struct SessionPermissionPresentation: Identifiable, Equatable, Sendable {
    let request: ProviderPermissionRequest

    var id: UUID { request.id }
}

struct SessionQuestionPresentation: Identifiable, Equatable, Sendable {
    let requestID: UUID
    let sessionID: String
    let questionIndex: Int
    let questionCount: Int
    let question: ProviderQuestion
    let selectedLabels: [String]
    /// The owner chose "Other…" and is typing their own answer.
    var isEnteringCustomAnswer = false

    var id: UUID { requestID }
}

enum PanelMode: Equatable, Sendable {
    case compact
    case sessions
    case update
    case onboarding
}

enum OnboardingStep: Equatable, Sendable {
    case working
    case permission
    case resolving(allowed: Bool)
    case complete(allowed: Bool)
}

@MainActor
final class ApplicationModel: ObservableObject {
    @Published private(set) var sessions: [SessionDisplayModel] = []
    @Published var panelMode: PanelMode = .compact
    @Published private(set) var onboardingStep: OnboardingStep = .working
    @Published private(set) var accessibility = AccessibilityEnvironment.current
    @Published private(set) var serverState: LocalServerState = .stopped
    @Published private(set) var pendingDecision: ChimloDecisionRequest?
    @Published private(set) var sessionPermissions: [String: SessionPermissionPresentation] = [:]
    @Published private(set) var sessionQuestions: [String: SessionQuestionPresentation] = [:]
    @Published private(set) var showsAllSessionsDuringOwnerInteraction = false
    @Published private(set) var islandLayout: IslandLayout
    @Published private(set) var claudeConnectionState: AgentConnectionState = .checking
    @Published private(set) var isScanningSessions = true
    @Published private(set) var capacitySnapshots: [CapacityProvider: ProviderCapacitySnapshot] = [:]
    @Published private(set) var capacityClock = Date.now
    @Published private(set) var showsUsageDetails = false
    @Published private(set) var updatePresentation: AppUpdatePresentation?
    /// The spectrum glow that says "Claude replied" after a finished turn.
    /// `showsCompletionGlow` drives its opacity; `animatesCompletionGlow` stays
    /// on through the fade-out so the colours keep flowing until it is gone.
    @Published private(set) var showsCompletionGlow = false
    @Published private(set) var animatesCompletionGlow = false
    @Published private(set) var sessionInsights: [String: TranscriptInsights] = [:]
    @Published private(set) var liveSessions: [String: ClaudeLiveSession] = [:]
    /// What the chosen notch layout shows, with Focus and motion folded in.
    @Published private(set) var layoutSpec: NotchLayoutSpec = NotchLayout.classic.spec
    /// The session the next/previous shortcuts moved to, highlighted in the
    /// panel and used by "Focus terminal".
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var isFocusModeActive = false
    @Published private(set) var contextAttentionThreshold = 0.7
    @Published private(set) var contextCriticalThreshold = 0.9
    /// How strongly the completion wave shows, 0...1; 0 turns it off.
    @Published private(set) var glowIntensity = 1.0
    /// Flips Overhead's Focus mode; set by the services.
    var toggleFocusMode: (() -> Void)?
    /// How loudly to announce an event. The services set this from the
    /// notification settings; without it every event is announced as before.
    var attentionDecider: ((AttentionEvent) -> NotificationDecision)?
    var usageWarningThreshold = 0.8

    let isUpdateTestMode: Bool

    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Keys.soundsEnabled) }
    }
    @Published var keepPreviewSession: Bool {
        didSet { defaults.set(keepPreviewSession, forKey: Keys.keepPreviewSession) }
    }

    private let defaults: UserDefaults
    private let updater = ChimloUpdater()
    private let chiptunePlayer = ChiptunePlayer()
    private var reducer = SessionReducer()
    private var demoSessionIDs: Set<String> = []
    private var previewSessionIDs: Set<String> = []
    private var deniedDemoSessionIDs: Set<String> = []
    private var hiddenSessionIDs: Set<String> = []
    private var archivedSessionMarkers: [String: SessionArchiveMarker]
    private var onboardingSessionID: String?
    private var onboardingEvents: [AgentEvent] = []
    private var onboardingTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var completionGlowTask: Task<Void, Never>?
    private var liveSessionTask: Task<Void, Never>?
    private var pointerInsideIsland = false
    private var decisionExpiryTask: Task<Void, Never>?
    private var decisionContinuation: CheckedContinuation<ChimloDecisionResponse, Never>?
    private var permissionRequests: [UUID: ProviderPermissionRequest] = [:]
    private var permissionContinuations: [UUID: CheckedContinuation<ProviderPermissionResponse, Never>] = [:]
    private var permissionExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var questionFlows: [UUID: QuestionFlow] = [:]
    private var questionContinuations: [UUID: CheckedContinuation<ProviderQuestionResponse, Never>] = [:]
    private var questionExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var protocolBridge: ProtocolBridge?
    private var hasStarted = false
    private lazy var integrationManager = AgentIntegrationManager.live()
    private let localSessionRuntime = LocalSessionRuntime()
    private let claudeUsageProbe = ClaudeUsageProbe()
    private var sessionRemovalTasks: [String: Task<Void, Never>] = [:]
    private var sessionActivityExpiryTask: Task<Void, Never>?
    private var sessionsArmedForCompletion: Set<String> = []
    private var latestResponseReceivedAt: [String: Date] = [:]
    private var completionDetailExpiryTasks: [String: Task<Void, Never>] = [:]
    private var lastPresentedResponse: [String: String] = [:]
    private var capacityMonitorTask: Task<Void, Never>?
    private var claudeUsageRefreshTask: Task<Void, Never>?
    private var lastClaudeUsageProbeAttemptAt: Date?
    private var capacityRefreshFailures: Set<CapacityProvider> = []
    private var displayMetrics = IslandDisplayMetrics(
        screenWidth: 0,
        screenHeight: 0,
        visibleTop: 0,
        safeTopInset: 0,
        cameraHousingLeftEdge: nil,
        cameraHousingRightEdge: nil
    )
    private var contextWarnedSessions: Set<String> = []
    private var usageWarnedWindows: Set<String> = []

    var panelSize: CGSize {
        switch panelMode {
        case .compact:
            return CGSize(width: islandLayout.compactWidth, height: islandLayout.compactHeight)
        case .sessions:
            let responseTextWidth = max(1, islandLayout.expandedWidth - 56)
            let displayedRowHeights = displayedSessions.map { session in
                session.preferredRowHeight(
                    responseTextWidth: responseTextWidth,
                    includesMetaLine: showsMetaLine(for: session)
                )
            }
            let contentHeight = SessionListLayout.contentHeight(
                displayedRowHeights: displayedRowHeights,
                hasSessions: !sessions.isEmpty,
                hasDecision: pendingDecision != nil,
                showsDisclosureControl: canRevealAllSessions,
                isDisclosureContextActive: hasActiveOwnerInteraction
            )
            return CGSize(
                width: islandLayout.expandedWidth,
                height: islandLayout.expandedContentTopInset
                    + contentHeight
                    + (showsUsageDetails ? CapacityLayout.disclosureHeight : 0)
            )
        case .update:
            return CGSize(
                width: max(
                    islandLayout.expandedNeckWidth,
                    min(360, islandLayout.expandedWidth)
                ),
                height: max(islandLayout.expandedContentTopInset, 4) + 52
            )
        case .onboarding:
            return CGSize(
                width: islandLayout.expandedWidth,
                height: max(islandLayout.expandedContentTopInset, 36)
                    + onboardingBodyHeight
            )
        }
    }

    var onboardingSession: SessionDisplayModel? {
        guard let onboardingSessionID else { return nil }
        return sessions.first { $0.id == onboardingSessionID }
    }

    private var onboardingBodyHeight: CGFloat {
        switch onboardingStep {
        case .working: 172
        case .permission: 208
        case .resolving: 138
        case .complete: 174
        }
    }

    var displayedSessions: [SessionDisplayModel] {
        guard hasActiveOwnerInteraction,
              !showsAllSessionsDuringOwnerInteraction else { return sessions }
        if pendingDecision != nil { return [] }
        return sessions.filter(\.hasActiveOwnerInteraction)
    }

    var canRevealAllSessions: Bool {
        hasActiveOwnerInteraction
            && !showsAllSessionsDuringOwnerInteraction
            && displayedSessions.count < sessions.count
    }

    func revealAllSessions() {
        guard canRevealAllSessions else { return }
        showsAllSessionsDuringOwnerInteraction = true
    }

    var activeMood: AvatarMood {
        if pendingDecision != nil { return .waiting }
        if let attention = sessions.first(where: \.needsAttention) { return attention.mood }
        if let working = sessions.first(where: { $0.mood == .working }) { return working.mood }
        return sessions.first?.mood ?? .idle
    }

    var compactLabel: String {
        if pendingDecision != nil || sessions.contains(where: { $0.mood == .waiting }) { return "WAIT" }
        if sessions.contains(where: { $0.mood == .question }) { return "ASK" }
        if sessions.contains(where: { $0.mood == .failed }) { return "STOP" }
        if sessions.contains(where: { $0.mood == .working }) { return "WORK" }
        if sessions.contains(where: { $0.mood == .success }) { return "DONE" }
        return "READY"
    }

    private var hasActiveOwnerInteraction: Bool {
        pendingDecision != nil || sessions.contains(where: \.hasActiveOwnerInteraction)
    }

    var claudeConnectionText: String {
        connectionText(state: claudeConnectionState)
    }

    var hasInstalledAgent: Bool {
        claudeConnectionState.isInstalled
    }

    var isReceivingAgentEvents: Bool {
        claudeConnectionState.isReceiving
    }

    var connectionSummary: String {
        if isScanningSessions { return "scanning" }
        if isReceivingAgentEvents { return "live" }
        if hasInstalledAgent { return "awaiting event" }
        return "setup needed"
    }

    init(
        defaults: UserDefaults = .standard,
        isUpdateTestMode: Bool = Bundle.main.object(
            forInfoDictionaryKey: "ChimloUpdateTestMode"
        ) as? Bool ?? false
    ) {
        self.defaults = defaults
        self.isUpdateTestMode = isUpdateTestMode
        archivedSessionMarkers = Self.loadArchivedSessionMarkers(from: defaults)
        islandLayout = IslandLayout.make(
            for: IslandDisplayMetrics(
                screenWidth: 0,
                screenHeight: 0,
                visibleTop: 0,
                safeTopInset: 0,
                cameraHousingLeftEdge: nil,
                cameraHousingRightEdge: nil
            )
        )
        soundsEnabled = defaults.object(forKey: Keys.soundsEnabled) as? Bool ?? true
        keepPreviewSession = defaults.object(forKey: Keys.keepPreviewSession) as? Bool ?? true
        for provider in CapacityProvider.allCases {
            if let snapshot = try? ProviderCapacityFile.load(from: Self.capacityCacheURL(for: provider)) {
                capacitySnapshots[provider] = snapshot
            }
        }
        updater.presentationChanged = { [weak self] presentation in
            self?.updatePresentationChanged(presentation)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        if isUpdateTestMode {
            panelMode = .compact
            updater.start()
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )


        let bridge = ProtocolBridge()
        protocolBridge = bridge
        bridge.start(
            receive: { [weak self] event in
                self?.receiveLiveEvent(event)
            },
            decide: { [weak self] request in
                guard let self else {
                    return .unavailable(for: request.id, reason: "Claude Overhead is closing")
                }
                return await self.requestDecision(request)
            },
            permit: { [weak self] request in
                guard let self else {
                    return .unavailable(for: request.id, reason: "Claude Overhead is closing")
                }
                return await self.requestPermission(request)
            },
            answer: { [weak self] request in
                guard let self else {
                    return .unavailable(for: request.id, reason: "Claude Overhead is closing")
                }
                return await self.requestQuestion(request)
            },
            stateChanged: { [weak self] state in
                self?.serverStateChanged(state)
            }
        )
        do {
            _ = try integrationManager.prepareStableHelper()
            try integrationManager.upgradeClaudeCapacityBridgeIfConnected()
        } catch {
            claudeConnectionState = .unavailable(error.localizedDescription)
        }
        configureSessionRuntime()
        startCapacityMonitoring()
        startLiveSessionMonitoring()
        localSessionRuntime.start()
        refreshAgentConnections()

        // First-launch setup runs in its own window (SetupCoordinator); the
        // notch starts idle and plays its preview only once setup asks.
        panelMode = preferredIdlePanelMode
        updater.start()
    }

    func stop() {
        hasStarted = false
        onboardingTask?.cancel()
        collapseTask?.cancel()
        decisionExpiryTask?.cancel()
        finishPendingDecision(outcome: .unavailable, note: "Claude Overhead closed before a decision was made")
        finishAllPendingPermissions(note: "Claude Overhead closed before permission was decided")
        finishAllPendingQuestions(note: "Claude Overhead closed before an answer was selected")
        protocolBridge?.stop()
        protocolBridge = nil
        localSessionRuntime.stop()
        capacityMonitorTask?.cancel()
        capacityMonitorTask = nil
        claudeUsageRefreshTask?.cancel()
        claudeUsageRefreshTask = nil
        sessionActivityExpiryTask?.cancel()
        sessionActivityExpiryTask = nil
        for task in sessionRemovalTasks.values { task.cancel() }
        sessionRemovalTasks.removeAll()
        for task in completionDetailExpiryTasks.values { task.cancel() }
        completionDetailExpiryTasks.removeAll()
        completionGlowTask?.cancel()
        completionGlowTask = nil
        liveSessionTask?.cancel()
        liveSessionTask = nil
        NotificationCenter.default.removeObserver(self)
    }

    func openPanel() {
        cancelCollapse()
        panelMode = .sessions
    }

    func collapsePanelFromOutsideClick() {
        guard panelMode == .sessions else { return }
        cancelCollapse()
        pointerInsideIsland = false
        showsUsageDetails = false
        panelMode = preferredIdlePanelMode
    }

    func pointerPresenceChanged(_ inside: Bool) {
        pointerInsideIsland = inside
        if inside {
            clearCompletionGlow()
            cancelCollapse()
            guard panelMode == .compact, layoutSpec.expandsOnHover else { return }
            panelMode = .sessions
        } else {
            scheduleCollapseAfterHover()
        }
    }

    private func scheduleCollapseAfterHover(
        delayMilliseconds: Int = IslandCollapsePolicy.hoverDelayMilliseconds
    ) {
        guard hasStarted, IslandCollapsePolicy.shouldCollapse(
            pointerInside: pointerInsideIsland,
            isSessionPanel: panelMode == .sessions,
            hasBlockingDecision: pendingDecision != nil
                || !sessionPermissions.isEmpty
                || !sessionQuestions.isEmpty
        ) else { return }
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self, hasStarted,
                  IslandCollapsePolicy.shouldCollapse(
                    pointerInside: pointerInsideIsland,
                    isSessionPanel: panelMode == .sessions,
                    hasBlockingDecision: pendingDecision != nil
                        || !sessionPermissions.isEmpty
                        || !sessionQuestions.isEmpty
                  ) else { return }
            showsUsageDetails = false
            panelMode = preferredIdlePanelMode
            collapseTask = nil
        }
    }

    func installUpdate() {
        guard updatePresentation?.isActionable == true else { return }
        cancelCollapse()
        updater.installAvailableUpdate()
    }

    func checkForUpdates() {
        cancelCollapse()
        updater.checkForUpdates()
    }

    private var preferredIdlePanelMode: PanelMode {
        AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            presentation: updatePresentation,
            hasOwnerInteraction: hasActiveOwnerInteraction,
            isOnboarding: panelMode == .onboarding
        ) ? .update : .compact
    }

    private func updatePresentationChanged(_ presentation: AppUpdatePresentation?) {
        updatePresentation = presentation
        if presentation == nil {
            if panelMode == .update { panelMode = .compact }
            return
        }
        let shouldTakeIdlePanel = AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            presentation: presentation,
            hasOwnerInteraction: hasActiveOwnerInteraction,
            isOnboarding: panelMode == .onboarding
        )
        guard shouldTakeIdlePanel else {
            if panelMode == .update { panelMode = .compact }
            return
        }
        cancelCollapse()
        showsUsageDetails = false
        panelMode = .update
    }

    func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    func toggleUsageDetails() {
        guard panelMode == .sessions else { return }
        cancelCollapse()
        showsUsageDetails.toggle()
        if showsUsageDetails {
            refreshClaudeCapacityFromCLIIfNeeded()
        }
    }

    func capacityReading(
        provider: CapacityProvider,
        kind: CapacityWindowKind
    ) -> CapacityReading {
        let snapshot = capacitySnapshots[provider]
        let window = snapshot?.window(kind)
        guard let window, !window.isExpired(at: capacityClock) else {
            return CapacityReading(
                window: nil,
                isApproximate: false,
                lastUpdatedAt: window?.observedAt ?? snapshot?.observedAt
            )
        }
        return CapacityReading(
            window: window,
            isApproximate: CapacityPolicy.isApproximate(
                window,
                refreshFailed: capacityRefreshFailures.contains(provider),
                now: capacityClock
            ),
            lastUpdatedAt: window.observedAt
        )
    }

    func primaryCapacityReading(for provider: CapacityProvider) -> CapacityReading {
        capacityReading(
            provider: provider,
            kind: .session
        )
    }

    func updateIslandLayout(_ layout: IslandLayout) {
        guard islandLayout != layout else { return }
        islandLayout = layout
    }

    /// The screen changed. The layout is rebuilt from these metrics and the
    /// chosen layout's wing width, so either change re-lays the notch.
    func updateDisplayMetrics(_ metrics: IslandDisplayMetrics) {
        displayMetrics = metrics
        rebuildIslandLayout()
    }

    /// Applies the owner's settings that the notch itself reads.
    func applySettings(_ settings: OverheadSettings, now: Date = .now) {
        let spec = settings.resolvedLayoutSpec(at: now, calendar: .current)
        if spec != layoutSpec {
            layoutSpec = spec
            rebuildIslandLayout()
        }
        let focus = settings.focus.isActive(at: now, calendar: .current)
        if focus != isFocusModeActive { isFocusModeActive = focus }
        if soundsEnabled != settings.notifications.soundsEnabled {
            soundsEnabled = settings.notifications.soundsEnabled
        }
        if contextAttentionThreshold != settings.contextAttentionThreshold {
            contextAttentionThreshold = settings.contextAttentionThreshold
        }
        if contextCriticalThreshold != settings.contextCriticalThreshold {
            contextCriticalThreshold = settings.contextCriticalThreshold
        }
        usageWarningThreshold = settings.usageWarningThreshold
        if glowIntensity != settings.glowIntensity { glowIntensity = settings.glowIntensity }
    }

    private func rebuildIslandLayout() {
        updateIslandLayout(IslandLayout.make(
            for: displayMetrics,
            wingWidthScale: CGFloat(layoutSpec.compactWingWidthScale)
        ))
    }

    /// Whether a session row shows its branch, context and agents line.
    func showsMetaLine(for session: SessionDisplayModel) -> Bool {
        layoutSpec.expandedRowDensity == .comfortable && !session.isDemo && SessionMetaLine.hasContent(session)
    }

    /// Motion is calmer when the layout, Focus, or the system asks for it.
    var reducesMotion: Bool {
        accessibility.reduceMotion || layoutSpec.animationScale < 0.3
    }

    // MARK: Session selection

    /// Moves the highlight through the sessions in panel order and opens the
    /// panel so the owner sees where it landed.
    func selectSession(offset: Int) {
        let ordered = displayedSessions.filter { !$0.isDemo }
        guard !ordered.isEmpty else { return }
        let current = selectedSessionID.flatMap { id in ordered.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = (current + offset % ordered.count + ordered.count) % ordered.count
        } else {
            next = offset >= 0 ? 0 : ordered.count - 1
        }
        selectedSessionID = ordered[next].id
        openPanel()
        scheduleCollapseAfterHover(delayMilliseconds: 4_000)
    }

    func selectSession(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
    }

    /// The session "Focus terminal" acts on: the highlighted one, else the
    /// one that needs the owner, else the most recent.
    var focusTargetSession: SessionDisplayModel? {
        if let selectedSessionID, let selected = sessions.first(where: { $0.id == selectedSessionID }) {
            return selected
        }
        return sessions.first(where: \.needsAttention) ?? sessions.first(where: { !$0.isDemo })
    }

    // MARK: Attention

    /// Asks the notification policy how to announce an event and returns
    /// whether to play its sound. Banners are posted by the decider.
    @discardableResult
    private func announce(
        _ kind: OverheadEventKind,
        key: String,
        sessionID: String?,
        title: String,
        body: String
    ) -> NotificationDecision {
        let event = AttentionEvent(kind: kind, key: key, sessionID: sessionID, title: title, body: body)
        if let attentionDecider { return attentionDecider(event) }
        return NotificationDecision(
            showInNotch: true,
            expandNotch: kind.priority == .critical,
            playSound: soundsEnabled && kind.priority != .ambient,
            postSystemBanner: false
        )
    }

    private func bannerTitle(for sessionID: String) -> String {
        guard let path = reducer.sessions[sessionID]?.projectPath else {
            return "Claude Code"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }

    func beginOnboardingDemo() {
        onboardingTask?.cancel()
        hideExistingDemoSessions()

        let sessionID = "overhead-onboarding-\(UUID().uuidString.lowercased())"
        onboardingSessionID = sessionID
        demoSessionIDs.insert(sessionID)
        onboardingEvents = makeOnboardingEvents(sessionID: sessionID, start: .now)
        panelMode = .onboarding
        onboardingStep = .working

        guard onboardingEvents.count >= 3 else { return }
        consume(onboardingEvents[0], isDemo: true)

        onboardingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            consume(onboardingEvents[1], isDemo: true)

            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            consume(onboardingEvents[2], isDemo: true)
            onboardingStep = .permission
        }
    }

    func resolveDemoPermission(allowed: Bool) {
        guard onboardingStep == .permission,
              let sessionID = onboardingSessionID,
              let current = reducer.sessions[sessionID] else { return }

        onboardingTask?.cancel()
        onboardingStep = .resolving(allowed: allowed)
        if allowed {
            deniedDemoSessionIDs.remove(sessionID)
        } else {
            deniedDemoSessionIDs.insert(sessionID)
        }

        consume(
            AgentEvent(
                sessionID: sessionID,
                sequence: current.lastSequence + 1,
                kind: .permissionResolved,
                agent: current.agent,
                detail: allowed ? "Running three focused checks" : "Request denied safely",
                decision: allowed ? .allow : .deny,
                timestamp: .now
            ),
            isDemo: true
        )

        onboardingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self,
                  let latest = reducer.sessions[sessionID] else { return }

            consume(
                AgentEvent(
                    sessionID: sessionID,
                    sequence: latest.lastSequence + 1,
                    kind: .completed,
                    agent: latest.agent,
                    detail: allowed ? "Three focused checks passed" : "Nothing ran and nothing changed",
                    timestamp: .now
                ),
                isDemo: true
            )
            onboardingStep = .complete(allowed: allowed)
        }
    }

    func finishOnboarding() {
        onboardingTask?.cancel()
        hideExistingDemoSessions()
        onboardingSessionID = nil
        onboardingEvents = []
        defaults.set(true, forKey: Keys.completedOnboarding)
        panelMode = preferredIdlePanelMode
        if sessions.isEmpty, keepPreviewSession, case .failed = serverState {
            installPreviewSession()
        }
    }

    /// Opens the setup window. `fromWelcome` replays the whole journey; otherwise
    /// it goes straight to reconnecting. Set by the app delegate.
    var presentSetup: ((_ fromWelcome: Bool) -> Void)?

    /// Setup finished with a verified connection at least once.
    var hasCompletedSetup: Bool { defaults.bool(forKey: Keys.completedOnboarding) }

    func markSetupCompleted() {
        defaults.set(true, forKey: Keys.completedOnboarding)
    }

    /// The notch's Connect and Repair buttons reconnect through the setup window.
    func beginReconnect() {
        if let presentSetup {
            presentSetup(false)
        } else {
            connectClaude()
        }
    }

    func playCue(_ cue: ChiptuneCue) {
        if soundsEnabled { chiptunePlayer.play(cue) }
    }

    func refreshAgentConnections() {
        claudeConnectionState = connectionState(for: .claude)
    }

    func connectClaude() {
        connect(.claude)
    }

    func disconnectClaude() {
        disconnect(.claude)
    }

    private func connect(_ provider: AgentProvider) {
        do {
            let preview = try integrationManager.preview(for: provider)
            guard confirmConnection(provider: provider, preview: preview) else {
                refreshAgentConnections()
                return
            }
            try integrationManager.connect(provider)
            setConnectionState(.installedAwaitingEvent, for: provider)
        } catch {
            setConnectionState(.unavailable(error.localizedDescription), for: provider)
        }
    }

    private func disconnect(_ provider: AgentProvider) {
        do {
            try integrationManager.disconnect(provider)
            defaults.removeObject(forKey: receiptKey(for: provider))
            setConnectionState(.disconnected, for: provider)
        } catch {
            setConnectionState(.unavailable(error.localizedDescription), for: provider)
        }
    }

    private func confirmConnection(provider: AgentProvider, preview: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Connect \(provider.displayName) to Claude Overhead?"
        let filename = "settings.json"
        let questionNote = provider == .claude
            ? " Claude questions and permissions route through Claude Overhead while it is running; Claude Code remains the fallback. The reversible status-line bridge stores only 5h and 7d usage limits and restores any existing custom status line on disconnect."
            : ""
        alert.informativeText = "Review the complete merged \(filename) below. Existing settings stay in place, and Claude Overhead keeps a one-time backup before writing.\(questionNote)"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 250))
        textView.string = preview
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        alert.accessoryView = scrollView

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func respondToPendingDecision(approved: Bool) {
        finishPendingDecision(outcome: approved ? .approved : .denied, note: nil)
    }

    func respondToSessionPermission(
        sessionID: String,
        outcome: ProviderPermissionOutcome
    ) {
        guard let request = sessionPermissions[sessionID]?.request,
              outcome == .allowedOnce
                || outcome == .denied
                || outcome == .allowedForSession else {
            return
        }
        finishPermission(requestID: request.id, outcome: outcome, note: nil)
    }

    func selectQuestionOption(sessionID: String, label: String) {
        guard let presentation = sessionQuestions[sessionID],
              var flow = questionFlows[presentation.requestID],
              let option = flow.currentQuestion.options.first(where: { $0.label == label }) else {
            return
        }

        if flow.currentQuestion.allowsMultipleSelections {
            if flow.selectedLabels.contains(option.label) {
                flow.selectedLabels.remove(option.label)
            } else {
                flow.selectedLabels.insert(option.label)
            }
            questionFlows[flow.request.id] = flow
            publishQuestion(flow)
        } else {
            flow.answers[flow.currentQuestion.prompt] = option.label
            advanceOrFinish(flow)
        }
    }

    func submitQuestionSelections(sessionID: String) {
        guard let presentation = sessionQuestions[sessionID],
              var flow = questionFlows[presentation.requestID],
              flow.currentQuestion.allowsMultipleSelections,
              !flow.selectedLabels.isEmpty else { return }
        let ordered = flow.currentQuestion.options.compactMap { option in
            flow.selectedLabels.contains(option.label) ? option.label : nil
        }
        flow.answers[flow.currentQuestion.prompt] = ordered.joined(separator: ", ")
        advanceOrFinish(flow)
    }

    /// Opens the "Other…" field, like Claude Code's own prompt offers.
    func beginCustomAnswer(sessionID: String) {
        guard let presentation = sessionQuestions[sessionID],
              var flow = questionFlows[presentation.requestID] else { return }
        cancelCollapse()
        flow.isEnteringCustomAnswer = true
        questionFlows[flow.request.id] = flow
        publishQuestion(flow)
    }

    func cancelCustomAnswer(sessionID: String) {
        guard let presentation = sessionQuestions[sessionID],
              var flow = questionFlows[presentation.requestID] else { return }
        flow.isEnteringCustomAnswer = false
        questionFlows[flow.request.id] = flow
        publishQuestion(flow)
    }

    /// Sends the owner's own words as the answer. Empty or oversized text is
    /// ignored rather than sent, so nothing reaches Claude by accident.
    func submitCustomAnswer(sessionID: String, text: String) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeQuestionHook.isValidCustomAnswer(answer),
              let presentation = sessionQuestions[sessionID],
              var flow = questionFlows[presentation.requestID] else { return }
        flow.answers[flow.currentQuestion.prompt] = answer
        flow.isEnteringCustomAnswer = false
        advanceOrFinish(flow)
    }

    func answerQuestionInClaudeCode(sessionID: String) {
        guard let requestID = sessionQuestions[sessionID]?.requestID else { return }
        finishQuestion(
            requestID: requestID,
            outcome: .cancelled,
            answers: [:],
            note: "Answering in Claude Code"
        )
    }

    func open(_ session: SessionDisplayModel) {
        guard let jumpURL = session.jumpURL else { return }
        NSWorkspace.shared.open(jumpURL)
    }

    func archiveSession(_ session: SessionDisplayModel) {
        guard !session.isDemo,
              let source = reducer.sessions[session.id],
              source.pendingRequest == nil else { return }

        archivedSessionMarkers[session.id] = SessionArchiveMarker()
        persistArchivedSessionMarkers()
        syncSessionProjections()
    }

    private func receiveLiveEvent(_ event: AgentEvent) {
        hiddenSessionIDs.formUnion(previewSessionIDs)
        recordReceipt(for: event.agent)
        guard event.sequence == 0 else {
            consume(event, isDemo: false)
            if event.kind == .sessionEnded { scheduleSessionRemoval(event.sessionID) }
            return
        }

        // Hook helpers are short-lived and can run concurrently. Claude Overhead owns
        // their ordering so adapters need no shared counter or lock.
        if reducer.sessions[event.sessionID] == nil, event.kind != .sessionStarted {
            consume(
                AgentEvent(
                    sessionID: event.sessionID,
                    sequence: 1,
                    kind: .sessionStarted,
                    agent: event.agent,
                    title: event.title,
                    detail: "Connected locally",
                    model: event.model,
                    terminal: event.terminal,
                    projectPath: event.projectPath,
                    jumpURL: event.jumpURL,
                    timestamp: event.timestamp
                ),
                isDemo: false
            )
        }

        let nextSequence = (reducer.sessions[event.sessionID]?.lastSequence ?? 0) + 1
        consume(event.replacingSequence(with: nextSequence), isDemo: false)
        if event.kind == .sessionEnded {
            scheduleSessionRemoval(event.sessionID)
        }
    }

    private func consume(_ event: AgentEvent, isDemo: Bool) {
        if isDemo { demoSessionIDs.insert(event.sessionID) }
        let wasArmedForCompletion = sessionsArmedForCompletion.contains(event.sessionID)
        let result = reducer.apply(event)
        guard case .applied = result else { return }
        if !isDemo { restoreArchivedSessionIfNeeded(for: event) }
        let isNewCompletion = IslandCollapsePolicy.isNewCompletion(
            wasArmedForCompletion: wasArmedForCompletion,
            eventKind: event.kind
        )
        if isNewCompletion { flashCompletionGlow() }
        var completionReceivedAt: Date?
        if isNewCompletion,
           reducer.sessions[event.sessionID]?.latestAgentResponse != nil {
            let receivedAt = latestResponseReceivedAt[event.sessionID] ?? .now
            recordLatestResponse(for: event.sessionID, receivedAt: receivedAt)
            completionReceivedAt = receivedAt
        }
        updateCompletionArm(for: event)
        syncSessionProjections()
        if !isDemo { localSessionRuntime.persist(reducer.orderedSessions) }

        if let completionReceivedAt {
            announceCompletionIfNeeded(sessionID: event.sessionID, receivedAt: completionReceivedAt)
        }

        if !isDemo {
            announceLiveEvent(event)
        } else if soundsEnabled {
            switch event.kind {
            case .sessionStarted: chiptunePlayer.play(.arrival)
            case .permissionRequested, .questionRequested, .failed: chiptunePlayer.play(.attention)
            case .activity, .permissionResolved, .questionResolved, .completed, .sessionEnded: break
            }
        }

        if let session = reducer.sessions[event.sessionID],
           sessions.contains(where: { $0.id == event.sessionID }),
           (session.pendingRequest != nil || session.phase == .failed),
           panelMode != .onboarding {
            cancelCollapse()
            showsUsageDetails = false
            panelMode = .sessions
            scheduleCollapseAfterHover()
        }
    }

    /// One glow at a time: a completion while it shows (or fades) restarts the
    /// same glow instead of stacking a second one.
    private func flashCompletionGlow() {
        guard glowIntensity > 0 else { return }
        completionGlowTask?.cancel()
        animatesCompletionGlow = true
        showsCompletionGlow = true
        completionGlowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IslandCollapsePolicy.completionGlowSeconds))
            guard !Task.isCancelled, let self else { return }
            showsCompletionGlow = false
            try? await Task.sleep(for: .seconds(IslandCollapsePolicy.completionGlowFadeSeconds))
            guard !Task.isCancelled else { return }
            animatesCompletionGlow = false
        }
    }

    private func clearCompletionGlow() {
        completionGlowTask?.cancel()
        completionGlowTask = nil
        showsCompletionGlow = false
        animatesCompletionGlow = false
    }

    private func updateCompletionArm(for event: AgentEvent) {
        switch event.kind {
        case .sessionStarted, .activity, .permissionResolved, .questionResolved:
            sessionsArmedForCompletion.insert(event.sessionID)
            lastPresentedResponse.removeValue(forKey: event.sessionID)
        case .completed, .failed, .sessionEnded:
            sessionsArmedForCompletion.remove(event.sessionID)
        case .permissionRequested, .questionRequested:
            break
        }
    }

    private func recordLatestResponse(for sessionID: String, receivedAt: Date) {
        let observedAt = min(receivedAt, .now)
        let lifetime = IslandCollapsePolicy.completionDetailLifetimeSeconds
        guard observedAt >= Date.now.addingTimeInterval(-lifetime) else { return }
        if let current = latestResponseReceivedAt[sessionID], current > observedAt { return }

        latestResponseReceivedAt[sessionID] = observedAt
        completionDetailExpiryTasks.removeValue(forKey: sessionID)?.cancel()

        let remainingSeconds = max(0, observedAt.addingTimeInterval(lifetime).timeIntervalSinceNow)
        let nanoseconds = UInt64(remainingSeconds * 1_000_000_000)
        completionDetailExpiryTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self,
                  latestResponseReceivedAt[sessionID] == observedAt else { return }
            latestResponseReceivedAt.removeValue(forKey: sessionID)
            completionDetailExpiryTasks.removeValue(forKey: sessionID)
            syncSessionProjections()
        }
    }

    /// Plays the success sound once per new reply. The panel stays closed: the
    /// orange notch glow says "Claude replied", and the owner opens it on hover.
    private func announceCompletionIfNeeded(sessionID: String, receivedAt: Date) {
        guard sessions.contains(where: { $0.id == sessionID }),
              panelMode != .onboarding,
              receivedAt >= Date.now.addingTimeInterval(
                -IslandCollapsePolicy.completionDetailLifetimeSeconds
              ),
              let response = reducer.sessions[sessionID]?.latestAgentResponse,
              lastPresentedResponse[sessionID] != response else { return }

        lastPresentedResponse[sessionID] = response
        if demoSessionIDs.contains(sessionID) {
            if soundsEnabled { chiptunePlayer.play(.success) }
            return
        }
        let decision = announce(
            .sessionCompleted,
            key: "\(sessionID)|\(response.hashValue)",
            sessionID: sessionID,
            title: bannerTitle(for: sessionID),
            body: "Claude finished and is waiting for you."
        )
        if decision.playSound { chiptunePlayer.play(.success) }
    }

    /// Sounds and banners for a hook event, as the notification settings say.
    private func announceLiveEvent(_ event: AgentEvent) {
        let sessionID = event.sessionID
        let title = bannerTitle(for: sessionID)
        let decision: NotificationDecision
        let cue: ChiptuneCue
        switch event.kind {
        case .sessionStarted:
            decision = announce(.sessionStarted, key: sessionID, sessionID: sessionID,
                                title: title, body: "A Claude Code session started.")
            cue = .arrival
        case .permissionRequested:
            decision = announce(.permissionRequested, key: "\(sessionID)|\(event.sequence)", sessionID: sessionID,
                                title: title, body: "Claude needs your permission to continue.")
            cue = .attention
        case .questionRequested:
            decision = announce(.questionAsked, key: "\(sessionID)|\(event.sequence)", sessionID: sessionID,
                                title: title, body: "Claude has a question for you.")
            cue = .attention
        case .failed:
            decision = announce(.sessionFailed, key: sessionID, sessionID: sessionID,
                                title: title, body: "The Claude Code session stopped with an error.")
            cue = .attention
        case .activity, .permissionResolved, .questionResolved, .completed, .sessionEnded:
            return
        }
        if decision.playSound { chiptunePlayer.play(cue) }
    }

    /// A context window crossing the attention threshold is worth one
    /// informational nudge per crossing; compaction re-arms it.
    private func announceContextWarnings() {
        for (sessionID, insight) in sessionInsights {
            guard let fraction = insight.contextFraction else { continue }
            if fraction < contextAttentionThreshold {
                contextWarnedSessions.remove(sessionID)
                continue
            }
            guard !contextWarnedSessions.contains(sessionID),
                  sessions.contains(where: { $0.id == sessionID && !$0.isDemo }) else { continue }
            contextWarnedSessions.insert(sessionID)
            let percent = Int((fraction * 100).rounded())
            let decision = announce(
                .contextWarning,
                key: sessionID,
                sessionID: sessionID,
                title: bannerTitle(for: sessionID),
                body: "Context is \(percent)% full. Claude Code will compact soon."
            )
            if decision.playSound { chiptunePlayer.play(.attention) }
        }
    }

    /// The 5-hour or weekly limit crossing the warning threshold.
    private func announceUsageWarnings(_ snapshot: ProviderCapacitySnapshot) {
        for window in snapshot.windows {
            let key = "\(window.kind.rawValue)|\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
            let used = window.usedPercentage / 100
            guard used >= usageWarningThreshold, !window.isExpired() else { continue }
            guard usageWarnedWindows.insert(key).inserted else { continue }
            let name = window.kind == .weekly ? "weekly" : "5-hour"
            let decision = announce(
                .usageWarning,
                key: key,
                sessionID: nil,
                title: "Claude usage",
                body: "You have used \(Int(window.usedPercentage.rounded()))% of your \(name) limit."
            )
            if decision.playSound { chiptunePlayer.play(.attention) }
        }
    }

    private func syncSessionProjections() {
        let now = Date.now
        let projectedSessions: [SessionDisplayModel] = reducer.orderedSessions.compactMap { session in
            let isDemo = demoSessionIDs.contains(session.id)
            let hasActionableRequest = session.pendingRequest != nil
                || sessionPermissions[session.id] != nil
                || sessionQuestions[session.id] != nil
            guard !hiddenSessionIDs.contains(session.id),
                  archivedSessionMarkers[session.id] == nil,
                  SessionVisibilityPolicy.wasActiveRecently(
                    updatedAt: session.updatedAt,
                    now: now
                  ),
                  SessionVisibilityPolicy.shouldDisplay(
                    title: session.title,
                    titleKind: session.titleKind,
                    isDemo: isDemo,
                    hasActionableRequest: hasActionableRequest,
                    hasConversationPreview: session.latestUserPrompt != nil
                        || session.latestAgentResponse != nil
                  ) else {
                return nil
            }
            return SessionDisplayModel(
                id: session.id,
                agentName: Self.agentName(session.agent),
                title: session.title,
                detail: session.detail,
                mood: mood(for: session),
                isDemo: isDemo,
                needsAttention: session.pendingRequest != nil
                    || sessionPermissions[session.id] != nil
                    || session.phase == .failed,
                terminal: session.terminal,
                projectPath: session.projectPath,
                jumpURL: session.jumpURL,
                model: ModelDisplayName.resolve(
                    modelID: session.model,
                    agent: session.agent
                ),
                updatedAt: session.updatedAt,
                latestUserPrompt: session.latestUserPrompt,
                latestAgentResponse: session.latestAgentResponse,
                latestResponseReceivedAt: latestResponseReceivedAt[session.id],
                permission: sessionPermissions[session.id],
                question: sessionQuestions[session.id],
                insights: sessionInsights[session.id],
                live: liveSessions[session.id]
            )
        }

        sessions = projectedSessions.enumerated().sorted { left, right in
            if left.element.hasActiveOwnerInteraction
                != right.element.hasActiveOwnerInteraction {
                return left.element.hasActiveOwnerInteraction
            }
            return left.offset < right.offset
        }.map { $0.element }
        resetSessionRevealIfNoOwnerInteraction()
        scheduleSessionActivityExpiry(now: now)
    }

    private func scheduleSessionActivityExpiry(now: Date) {
        sessionActivityExpiryTask?.cancel()
        sessionActivityExpiryTask = nil
        let nextExpiration = sessions
            .map { $0.updatedAt.addingTimeInterval(SessionVisibilityPolicy.activityLifetime) }
            .filter { $0 > now }
            .min()
        guard hasStarted, let nextExpiration else { return }

        let delaySeconds = min(
            SessionVisibilityPolicy.activityLifetime,
            max(0.001, nextExpiration.timeIntervalSince(now))
        )
        let delayMilliseconds = max(1, Int(ceil(delaySeconds * 1_000)))
        sessionActivityExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self else { return }
            sessionActivityExpiryTask = nil
            syncSessionProjections()
        }
    }

    private func resetSessionRevealIfNoOwnerInteraction() {
        guard !hasActiveOwnerInteraction else { return }
        showsAllSessionsDuringOwnerInteraction = false
    }

    private func configureSessionRuntime() {
        localSessionRuntime.onCandidate = { [weak self] candidate in
            self?.receive(candidate)
        }
        localSessionRuntime.onSessionEnded = { [weak self] sessionID in
            self?.scheduleSessionRemoval(sessionID)
        }
        localSessionRuntime.onInitialScanCompleted = { [weak self] in
            self?.isScanningSessions = false
        }
        localSessionRuntime.onInsights = { [weak self] insights in
            self?.receiveInsights(insights)
        }
    }

    private func receiveInsights(_ insights: [String: TranscriptInsights]) {
        var merged = sessionInsights
        merged.merge(insights) { _, newer in newer }
        guard merged != sessionInsights else { return }
        sessionInsights = merged
        syncSessionProjections()
        announceContextWarnings()
    }

    /// Claude Code's own list of live sessions (`claude agents --json`, about
    /// 0.1 s): it shows background sessions and exact pids. Every 15 s, and
    /// only when the command line is installed.
    private func startLiveSessionMonitoring() {
        liveSessionTask?.cancel()
        let environment = ProcessInfo.processInfo.environment
        guard let executable = ClaudeCodeLocator.executableCandidates(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            path: environment["PATH"]
        ).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }

        liveSessionTask = Task { [weak self] in
            while !Task.isCancelled {
                let listing = await Task.detached(priority: .utility) { () -> [ClaudeLiveSession] in
                    guard let output = LocalAgentProcessDiscovery.commandOutput(
                        executable: executable,
                        arguments: ["agents", "--json"]
                    ) else { return [] }
                    return ClaudeAgentsListing.parse(Data(output.utf8))
                }.value
                guard !Task.isCancelled, let self else { return }
                let byID = Dictionary(listing.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
                if byID != liveSessions {
                    liveSessions = byID
                    syncSessionProjections()
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func startCapacityMonitoring() {
        refreshClaudeCapacityFromCache()
        capacityMonitorTask?.cancel()
        capacityMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                capacityClock = .now
                refreshClaudeCapacityFromCache()
                if showsUsageDetails {
                    refreshClaudeCapacityFromCLIIfNeeded()
                }
            }
        }
    }

    private func refreshClaudeCapacityFromCache() {
        let url = Self.capacityCacheURL(for: .claude)
        guard let snapshot = try? ProviderCapacityFile.load(from: url),
              snapshot.provider == .claude,
              snapshot.observedAt > (capacitySnapshots[.claude]?.observedAt ?? .distantPast) else {
            return
        }
        receiveCapacity(snapshot, persist: false)
    }

    private func refreshClaudeCapacityFromCLIIfNeeded() {
        let now = Date.now
        guard claudeUsageRefreshTask == nil,
              CapacityPolicy.shouldProbeClaudeUsage(
                snapshot: capacitySnapshots[.claude],
                lastAttemptAt: lastClaudeUsageProbeAttemptAt,
                now: now
              ) else {
            return
        }

        lastClaudeUsageProbeAttemptAt = now
        claudeUsageRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { claudeUsageRefreshTask = nil }
            do {
                let probed = try await claudeUsageProbe.fetch()
                guard !Task.isCancelled else { return }
                let snapshot = probed.preservingValidResetTimes(
                    from: capacitySnapshots[.claude]
                )
                receiveCapacity(snapshot)
            } catch is CancellationError {
                return
            } catch {
                capacityRefreshFailures.insert(.claude)
                capacityClock = .now
            }
        }
    }

    private func receiveCapacity(
        _ snapshot: ProviderCapacitySnapshot,
        persist: Bool = true
    ) {
        capacitySnapshots[snapshot.provider] = snapshot
        capacityRefreshFailures.remove(snapshot.provider)
        capacityClock = .now
        if snapshot.provider == .claude { announceUsageWarnings(snapshot) }
        if persist {
            try? ProviderCapacityFile.write(
                snapshot,
                to: Self.capacityCacheURL(for: snapshot.provider)
            )
        }
    }

    private static func capacityCacheURL(for provider: CapacityProvider) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Overhead", isDirectory: true)
            .appendingPathComponent("capacity", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue).json")
    }

    private func receive(_ candidate: SessionCandidate) {
        hiddenSessionIDs.formUnion(previewSessionIDs)
        sessionRemovalTasks.removeValue(forKey: candidate.id)?.cancel()
        restoreArchivedSessionIfNeeded(for: candidate)
        let previous = reducer.sessions[candidate.id]
        let merged = reducer.merge(candidate)
        let hasNewResponse = candidate.latestAgentResponse != nil
            && candidate.latestAgentResponse != previous?.latestAgentResponse

        if merged.phase == .working, previous?.phase != .working {
            lastPresentedResponse.removeValue(forKey: candidate.id)
        }
        if hasNewResponse,
           candidate.updatedAt >= Date.now.addingTimeInterval(
            -IslandCollapsePolicy.completionDetailLifetimeSeconds
           ) {
            recordLatestResponse(for: candidate.id, receivedAt: .now)
        }

        let finishedWithReply = merged.phase == .completed
            && merged.latestAgentResponse != nil
            && (previous?.phase != .completed || hasNewResponse)
        syncSessionProjections()
        localSessionRuntime.persist(reducer.orderedSessions)

        if finishedWithReply {
            announceCompletionIfNeeded(
                sessionID: candidate.id,
                receivedAt: latestResponseReceivedAt[candidate.id] ?? candidate.updatedAt
            )
        }
    }

    private func removeSession(_ sessionID: String) {
        sessionRemovalTasks.removeValue(forKey: sessionID)?.cancel()
        completionDetailExpiryTasks.removeValue(forKey: sessionID)?.cancel()
        sessionsArmedForCompletion.remove(sessionID)
        latestResponseReceivedAt.removeValue(forKey: sessionID)
        lastPresentedResponse.removeValue(forKey: sessionID)
        if archivedSessionMarkers.removeValue(forKey: sessionID) != nil {
            persistArchivedSessionMarkers()
        }
        guard reducer.remove(sessionID: sessionID) != nil else { return }
        syncSessionProjections()
        localSessionRuntime.persist(reducer.orderedSessions)
    }

    private func scheduleSessionRemoval(_ sessionID: String) {
        sessionRemovalTasks.removeValue(forKey: sessionID)?.cancel()
        let recentResponseDelay = latestResponseReceivedAt[sessionID].map { receivedAt in
            max(
                0,
                receivedAt.addingTimeInterval(
                    IslandCollapsePolicy.completionDetailLifetimeSeconds
                ).timeIntervalSinceNow
            )
        } ?? 0
        let delayMilliseconds = Int(ceil(max(4, recentResponseDelay) * 1_000))
        sessionRemovalTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }
            self?.removeSession(sessionID)
        }
    }

    private func recordReceipt(for agent: AgentKind) {
        let provider: AgentProvider?
        switch agent {
        case .claude: provider = .claude
        default: provider = nil
        }
        guard let provider else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: receiptKey(for: provider))
        refreshAgentConnections()
    }

    private func restoreArchivedSessionIfNeeded(for candidate: SessionCandidate) {
        guard let marker = archivedSessionMarkers[candidate.id],
              marker.shouldRestore(for: candidate) else { return }
        archivedSessionMarkers.removeValue(forKey: candidate.id)
        persistArchivedSessionMarkers()
    }

    private func restoreArchivedSessionIfNeeded(for event: AgentEvent) {
        guard let marker = archivedSessionMarkers[event.sessionID],
              marker.shouldRestore(for: event) else { return }
        archivedSessionMarkers.removeValue(forKey: event.sessionID)
        persistArchivedSessionMarkers()
    }

    private func persistArchivedSessionMarkers() {
        let values = archivedSessionMarkers.mapValues { $0.archivedAt.timeIntervalSince1970 }
        defaults.set(values, forKey: Keys.archivedSessions)
    }

    private static func loadArchivedSessionMarkers(
        from defaults: UserDefaults
    ) -> [String: SessionArchiveMarker] {
        guard let stored = defaults.dictionary(forKey: Keys.archivedSessions) else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            guard let timestamp = entry.value as? NSNumber else { return }
            result[entry.key] = SessionArchiveMarker(
                archivedAt: Date(timeIntervalSince1970: timestamp.doubleValue)
            )
        }
    }

    private func connectionState(for provider: AgentProvider) -> AgentConnectionState {
        let timestamp = defaults.double(forKey: receiptKey(for: provider))
        let receipt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        return integrationManager.status(for: provider, lastReceiptAt: receipt)
    }

    private func setConnectionState(_ state: AgentConnectionState, for provider: AgentProvider) {
        switch provider {
        case .claude: claudeConnectionState = state
        }
    }

    private func connectionText(state: AgentConnectionState) -> String {
        switch state {
        case .checking:
            "Checking"
        case .disconnected:
            "Not connected"
        case .installedAwaitingEvent:
            "Connected - waiting for activity"
        case let .receiving(date):
            "Active \(date.formatted(.relative(presentation: .named)))"
        case .needsRepair:
            "Repair needed"
        case let .unavailable(message):
            message
        }
    }

    private func receiptKey(for provider: AgentProvider) -> String {
        "overhead.integration.\(provider.rawValue).lastReceipt"
    }

    private func mood(for session: AgentSession) -> AvatarMood {
        if previewSessionIDs.contains(session.id) || deniedDemoSessionIDs.contains(session.id) {
            return .idle
        }
        switch session.phase {
        case .working:
            return .working
        case .waitingForApproval:
            return .waiting
        case .waitingForAnswer:
            return .question
        case .completed:
            return .success
        case .failed:
            return .failed
        }
    }

    private func serverStateChanged(_ state: LocalServerState) {
        serverState = state
        if case .failed = state, keepPreviewSession, sessions.isEmpty,
           defaults.bool(forKey: Keys.completedOnboarding) {
            installPreviewSession()
        }
    }

    private func requestDecision(_ request: ChimloDecisionRequest) async -> ChimloDecisionResponse {
        if let expiresAt = request.expiresAt, expiresAt <= Date() {
            return .unavailable(for: request.id, reason: "Decision request expired")
        }
        guard pendingDecision == nil, decisionContinuation == nil else {
            return .unavailable(for: request.id, reason: "Another decision is already awaiting the owner")
        }

        return await withCheckedContinuation { continuation in
            cancelCollapse()
            showsAllSessionsDuringOwnerInteraction = false
            pendingDecision = request
            decisionContinuation = continuation
            showsUsageDetails = false
            panelMode = .sessions
            scheduleDecisionExpiry(for: request)
        }
    }

    private func requestPermission(
        _ request: ProviderPermissionRequest
    ) async -> ProviderPermissionResponse {
        if let expiresAt = request.expiresAt, expiresAt <= Date() {
            return .unavailable(for: request.id, reason: "Permission request expired")
        }
        guard request.agent == .claude,
              !request.sessionID.isEmpty,
              !request.toolName.isEmpty,
              !request.prompt.isEmpty,
              request.allowsSessionApproval,
              sessionPermissions[request.sessionID] == nil,
              sessionQuestions[request.sessionID] == nil else {
            return .unavailable(
                for: request.id,
                reason: "This session already has a pending owner interaction"
            )
        }

        return await withCheckedContinuation { continuation in
            cancelCollapse()
            showsAllSessionsDuringOwnerInteraction = false
            permissionRequests[request.id] = request
            permissionContinuations[request.id] = continuation
            sessionPermissions[request.sessionID] = SessionPermissionPresentation(request: request)
            presentPermissionEvent(for: request)
            showsUsageDetails = false
            panelMode = .sessions
            schedulePermissionExpiry(for: request)
        }
    }

    private func presentPermissionEvent(for request: ProviderPermissionRequest) {
        receiveLiveEvent(
            AgentEvent(
                sessionID: request.sessionID,
                sequence: 0,
                kind: .permissionRequested,
                agent: request.agent,
                title: request.title,
                detail: "Permission from Claude Code",
                request: .approval(
                    ApprovalRequest(
                        id: request.id.uuidString,
                        summary: "Permission requested for \(request.toolName)"
                    )
                ),
                timestamp: .now
            )
        )
    }

    private func schedulePermissionExpiry(for request: ProviderPermissionRequest) {
        guard let expiresAt = request.expiresAt else { return }
        let nanoseconds = UInt64(max(0, expiresAt.timeIntervalSinceNow) * 1_000_000_000)
        permissionExpiryTasks[request.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.finishPermission(
                requestID: request.id,
                outcome: .unavailable,
                note: "Permission request expired"
            )
        }
    }

    private func finishPermission(
        requestID: UUID,
        outcome: ProviderPermissionOutcome,
        note: String?
    ) {
        guard let request = permissionRequests.removeValue(forKey: requestID) else { return }
        permissionExpiryTasks.removeValue(forKey: requestID)?.cancel()
        if sessionPermissions[request.sessionID]?.request.id == requestID {
            sessionPermissions.removeValue(forKey: request.sessionID)
        }

        if let current = reducer.sessions[request.sessionID] {
            let detail = switch outcome {
            case .allowedOnce: "Allowed once in Claude Code"
            case .allowedForSession: "Allowed for this Claude Code session"
            case .denied: "Permission denied in Claude Overhead"
            case .cancelled, .unavailable: "Answer in Claude Code"
            }
            let decision: UserDecision? = switch outcome {
            case .allowedOnce, .allowedForSession: .allow
            case .denied: .deny
            case .cancelled, .unavailable: nil
            }
            consume(
                AgentEvent(
                    sessionID: current.id,
                    sequence: current.lastSequence + 1,
                    kind: .permissionResolved,
                    agent: current.agent,
                    detail: detail,
                    decision: decision,
                    timestamp: .now
                ),
                isDemo: false
            )
        } else {
            syncSessionProjections()
        }

        let continuation = permissionContinuations.removeValue(forKey: requestID)
        continuation?.resume(returning: ProviderPermissionResponse(
            requestID: requestID,
            outcome: outcome,
            note: note
        ))
        scheduleCollapseAfterHover()
    }

    private func finishAllPendingPermissions(note: String) {
        let requestIDs = Array(permissionRequests.keys)
        for requestID in requestIDs {
            finishPermission(
                requestID: requestID,
                outcome: .unavailable,
                note: note
            )
        }
    }

    private func requestQuestion(_ request: ProviderQuestionRequest) async -> ProviderQuestionResponse {
        if let expiresAt = request.expiresAt, expiresAt <= Date() {
            return .unavailable(for: request.id, reason: "Question request expired")
        }
        guard !request.questions.isEmpty,
              request.questions.allSatisfy({ !$0.prompt.isEmpty && !$0.options.isEmpty }),
              sessionQuestions[request.sessionID] == nil,
              sessionPermissions[request.sessionID] == nil else {
            return .unavailable(for: request.id, reason: "This session already has a pending question")
        }

        return await withCheckedContinuation { continuation in
            cancelCollapse()
            showsAllSessionsDuringOwnerInteraction = false
            let flow = QuestionFlow(request: request)
            questionFlows[request.id] = flow
            questionContinuations[request.id] = continuation
            publishQuestion(flow)
            presentQuestionEvent(for: flow)
            showsUsageDetails = false
            panelMode = .sessions
            scheduleQuestionExpiry(for: request)
        }
    }

    private func advanceOrFinish(_ flow: QuestionFlow) {
        if flow.questionIndex + 1 < flow.request.questions.count {
            var next = flow
            next.questionIndex += 1
            next.selectedLabels.removeAll()
            next.isEnteringCustomAnswer = false
            showsAllSessionsDuringOwnerInteraction = false
            questionFlows[next.request.id] = next
            publishQuestion(next)
            presentQuestionEvent(for: next)
        } else {
            finishQuestion(
                requestID: flow.request.id,
                outcome: .answered,
                answers: flow.answers,
                note: nil
            )
        }
    }

    private func publishQuestion(_ flow: QuestionFlow) {
        sessionQuestions[flow.request.sessionID] = SessionQuestionPresentation(
            requestID: flow.request.id,
            sessionID: flow.request.sessionID,
            questionIndex: flow.questionIndex,
            questionCount: flow.request.questions.count,
            question: flow.currentQuestion,
            selectedLabels: flow.currentQuestion.options.compactMap { option in
                flow.selectedLabels.contains(option.label) ? option.label : nil
            },
            isEnteringCustomAnswer: flow.isEnteringCustomAnswer
        )
        syncSessionProjections()
    }

    private func presentQuestionEvent(for flow: QuestionFlow) {
        receiveLiveEvent(
            AgentEvent(
                sessionID: flow.request.sessionID,
                sequence: 0,
                kind: .questionRequested,
                agent: flow.request.agent,
                title: flow.request.title,
                detail: "Question from Claude Code",
                request: .question(
                    AgentQuestion(
                        id: "\(flow.request.id.uuidString)-\(flow.questionIndex)",
                        prompt: flow.currentQuestion.prompt,
                        options: flow.currentQuestion.options.map(\.label)
                    )
                ),
                timestamp: .now
            )
        )
    }

    private func scheduleQuestionExpiry(for request: ProviderQuestionRequest) {
        guard let expiresAt = request.expiresAt else { return }
        let nanoseconds = UInt64(max(0, expiresAt.timeIntervalSinceNow) * 1_000_000_000)
        questionExpiryTasks[request.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.finishQuestion(
                requestID: request.id,
                outcome: .unavailable,
                answers: [:],
                note: "Question request expired"
            )
        }
    }

    private func finishQuestion(
        requestID: UUID,
        outcome: ProviderQuestionOutcome,
        answers: [String: String],
        note: String?
    ) {
        guard let flow = questionFlows.removeValue(forKey: requestID) else { return }
        questionExpiryTasks.removeValue(forKey: requestID)?.cancel()
        sessionQuestions.removeValue(forKey: flow.request.sessionID)

        if let current = reducer.sessions[flow.request.sessionID] {
            consume(
                AgentEvent(
                    sessionID: current.id,
                    sequence: current.lastSequence + 1,
                    kind: .questionResolved,
                    agent: current.agent,
                    detail: outcome == .answered ? "Answer sent to Claude Code" : "Answer in Claude Code",
                    decision: outcome == .answered
                        ? .answer(answers.values.joined(separator: ", "))
                        : nil,
                    timestamp: .now
                ),
                isDemo: false
            )
        } else {
            syncSessionProjections()
        }

        let continuation = questionContinuations.removeValue(forKey: requestID)
        continuation?.resume(returning: ProviderQuestionResponse(
            requestID: requestID,
            outcome: outcome,
            answers: answers,
            note: note
        ))
        scheduleCollapseAfterHover()
    }

    private func finishAllPendingQuestions(note: String) {
        let requestIDs = Array(questionFlows.keys)
        for requestID in requestIDs {
            finishQuestion(
                requestID: requestID,
                outcome: .unavailable,
                answers: [:],
                note: note
            )
        }
    }

    private func scheduleDecisionExpiry(for request: ChimloDecisionRequest) {
        decisionExpiryTask?.cancel()
        guard let expiresAt = request.expiresAt else { return }
        let nanoseconds = UInt64(max(0, expiresAt.timeIntervalSinceNow) * 1_000_000_000)
        decisionExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self?.pendingDecision?.id == request.id else { return }
            self?.finishPendingDecision(outcome: .unavailable, note: "Decision request expired")
        }
    }

    private func finishPendingDecision(outcome: ChimloDecisionOutcome, note: String?) {
        guard let request = pendingDecision else { return }
        decisionExpiryTask?.cancel()
        decisionExpiryTask = nil
        let continuation = decisionContinuation
        decisionContinuation = nil
        pendingDecision = nil
        resetSessionRevealIfNoOwnerInteraction()
        continuation?.resume(
            returning: ChimloDecisionResponse(
                requestID: request.id,
                outcome: outcome,
                note: note
            )
        )
        scheduleCollapseAfterHover()
    }

    private func installPreviewSession() {
        guard !sessions.contains(where: \.isDemo) else { return }
        let sessionID = "overhead-listener-preview-\(UUID().uuidString.lowercased())"
        previewSessionIDs.insert(sessionID)
        demoSessionIDs.insert(sessionID)
        consume(
            AgentEvent(
                sessionID: sessionID,
                sequence: 1,
                kind: .sessionStarted,
                agent: .other,
                title: "Local listener preview",
                detail: "Waiting for the local server to become available",
                timestamp: .now
            ),
            isDemo: true
        )
    }

    private func hideExistingDemoSessions() {
        hiddenSessionIDs.formUnion(demoSessionIDs)
        syncSessionProjections()
    }

    private func makeOnboardingEvents(sessionID: String, start: Date) -> [AgentEvent] {
        DemoScript.make(start: start).map { beat in
            let event = beat.event
            return AgentEvent(
                id: UUID(),
                sessionID: sessionID,
                sequence: event.sequence,
                kind: event.kind,
                agent: event.agent,
                title: event.title,
                detail: event.detail,
                model: event.model,
                terminal: event.terminal,
                projectPath: event.projectPath,
                jumpURL: event.jumpURL,
                request: event.request,
                decision: event.decision,
                timestamp: start.addingTimeInterval(Double(beat.offsetMilliseconds) / 1_000)
            )
        }
    }

    private static func agentName(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        case .hermes: "Hermes"
        case .other: "Local agent"
        }
    }

    @objc private func accessibilityOptionsChanged() {
        accessibility = .current
    }

    private enum Keys {
        static let completedOnboarding = "overhead.onboarding.completed"
        static let soundsEnabled = "overhead.sound.enabled"
        static let keepPreviewSession = "overhead.preview.keepSession"
        static let archivedSessions = "overhead.sessions.archived"
    }

    private struct QuestionFlow {
        let request: ProviderQuestionRequest
        var questionIndex = 0
        var answers: [String: String] = [:]
        var selectedLabels: Set<String> = []
        var isEnteringCustomAnswer = false

        var currentQuestion: ProviderQuestion {
            request.questions[questionIndex]
        }
    }
}

private extension AgentEvent {
    func replacingSequence(with sequence: Int) -> AgentEvent {
        AgentEvent(
            id: id,
            sessionID: sessionID,
            sequence: sequence,
            kind: kind,
            agent: agent,
            title: title,
            detail: detail,
            model: model,
            terminal: terminal,
            projectPath: projectPath,
            jumpURL: jumpURL,
            request: request,
            decision: decision,
            timestamp: timestamp
        )
    }
}
