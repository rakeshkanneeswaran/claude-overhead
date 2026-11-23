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
    /// `.task` once Claude Code has titled the session.
    var titleKind: SessionTitleKind = .workspace
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
    /// Where the session stands, with stale work no longer called running.
    var runState: SessionRunState = .older

    var hasActiveOwnerInteraction: Bool {
        permission != nil || question != nil
    }

    var isRunning: Bool { runState == .running }

    /// The project folder's name, when it is known.
    var projectName: String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// The transcript's tool calls, oldest first.
    var activities: [SessionActivity] { insights?.activities ?? [] }

    /// The newest tool call of the turn in progress, only while running.
    var currentActivity: SessionActivity? {
        isRunning ? insights?.currentTurnActivity : nil
    }

    /// Claude Code's own session title, exactly, once it has one.
    var displayTitle: String {
        SessionTitle.display(title: title, kind: titleKind, projectPath: projectPath)
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

/// What GitHub Mode needs from the services, pushed whenever GitHub data or
/// GitHub settings change. The notch never talks to the network itself.
struct GitHubNotchPresentation: Equatable {
    /// GitHub is on and GitHub Mode is enabled.
    var modeAvailable = false
    var showsButton = false
    var indicator: GitHubIndicator = .unavailable
    var showsInClosedNotch = false
    var density: GitHubPanelDensity = .compact
    var defaultView: GitHubDefaultView = .overview
    var showsAccount = true
    var showsRepositoryInfo = true
    var showsDetailedMetadata = true
    /// Offer Merge on pull requests GitHub says are ready.
    var allowsMerging = true
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
    @Published var panelMode: PanelMode = .compact {
        // A closed notch reopens on Claude. GitHub Mode keeps its tab and
        // detail for the next time the owner enters it.
        didSet {
            // Leaving the tour by anything but its own buttons (a shortcut, a
            // banner) ends it too, so its demo session never stays behind as
            // a request nobody can answer.
            if oldValue == .onboarding, panelMode != .onboarding, onboardingSessionID != nil { closeTour() }
            if panelMode == .sessions, oldValue != .sessions {
                // The cards have only just come into view: a click already
                // on its way must not land on one.
                clickGuard.cardsMoved(at: Self.uptime)
                // The open notch shows usage top left: freshen it if it is old.
                refreshClaudeCapacityFromCLIIfNeeded()
            }
            guard panelMode == .compact else { return }
            if githubNavigation.content == .github { githubNavigation.returnToClaude() }
            // A closed notch reopens on the session list.
            inspectedSessionID = nil
        }
    }
    /// GitHub Mode's place: tab, detail and filter. Separate from every
    /// Claude property, so moving between the modes changes neither.
    @Published var githubNavigation = GitHubNavigation()
    @Published private(set) var github = GitHubNotchPresentation()
    /// Called when the owner enters GitHub Mode, to mark activity as seen.
    var onGitHubModeOpened: (() -> Void)?
    /// Opens the GitHub page on Integration (sign-in, repositories,
    /// preferences); set by the services.
    var openGitHubIntegration: (() -> Void)?
    /// Opens the companion window's GitHub page, optionally on one detail.
    var openGitHubInCompanion: ((GitHubDetail?) -> Void)?
    @Published private(set) var onboardingStep: OnboardingStep = .working
    @Published private(set) var accessibility = AccessibilityEnvironment.current
    @Published private(set) var serverState: LocalServerState = .stopped
    @Published private(set) var pendingDecision: ChimloDecisionRequest? {
        didSet { updateCompactActivity() }
    }
    @Published private(set) var sessionPermissions: [String: SessionPermissionPresentation] = [:]
    @Published private(set) var sessionQuestions: [String: SessionQuestionPresentation] = [:]
    @Published private(set) var showsAllSessionsDuringOwnerInteraction = false
    @Published private(set) var islandLayout: IslandLayout
    @Published private(set) var claudeConnectionState: AgentConnectionState = .checking
    @Published private(set) var isScanningSessions = true
    @Published private(set) var capacitySnapshots: [CapacityProvider: ProviderCapacitySnapshot] = [:]
    @Published private(set) var capacityClock = Date.now
    @Published private(set) var showsUsageDetails = false
    /// The latest update state, for Settings.
    @Published private(set) var updatePresentation: AppUpdatePresentation?
    /// The notch's update row: the same state, until it is closed or a
    /// finished state's lifetime runs out.
    @Published private(set) var updateNotice = AppUpdateNotice()
    private var updateNoticeExpiryTask: Task<Void, Never>?
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
    /// The session whose activity feed the open notch shows, if any.
    @Published private(set) var inspectedSessionID: String?
    /// The closed notch's activity strip. Shown at once, hidden after a short
    /// hold, so the notch does not resize between two turns.
    @Published private(set) var compactActivity: CompactActivityLine?
    /// Whether the strip may show at all (`OverheadSettings.showsClosedNotchActivity`).
    private var showsClosedNotchActivity = true
    @Published private(set) var isFocusModeActive = false
    @Published private(set) var contextAttentionThreshold = 0.7
    @Published private(set) var contextCriticalThreshold = 0.9
    /// How strongly the completion wave shows, 0...1; 0 turns it off.
    @Published private(set) var glowIntensity = 1.0
    /// Which display the notch lives on (`OverheadSettings.preferredDisplay`).
    /// The window coordinator turns it into a screen.
    @Published private(set) var preferredDisplay: DisplayPreference = .notchedDisplay
    /// Flips Overhead's Focus mode; set by the services.
    var toggleFocusMode: (() -> Void)?
    /// Brings a session's terminal or editor forward; set by the services.
    var focusSessionHost: ((SessionDisplayModel) -> Void)?
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
    /// The owner's setting: whether requests from runs nobody is watching
    /// (`claude -p`) wait in the notch. Off, they are left to Claude Code.
    private var asksAboutUnattendedRuns = false
    /// Lock Mode: the notch opens only when the owner opens it. Requests
    /// still wait in it; nothing is approved or dropped.
    @Published var isNotchLocked = false {
        didSet {
            guard isNotchLocked != oldValue else { return }
            if isNotchLocked {
                if panelMode == .update { panelMode = .compact }
            } else if NotchLockPolicy.opensOnUnlock(hasPendingOwnerRequest: hasActiveOwnerInteraction),
                      panelMode == .compact || panelMode == .update {
                openPanel()
            } else {
                syncUpdatePanel()
            }
        }
    }
    /// Which sessions may make sounds: none until the owner turns a
    /// session's bell on in the notch. Kept for the session's lifetime.
    @Published private(set) var soundPreferences = SessionSoundPreferences()
    private var soundGate = SessionSoundGate()
    /// Which clicks on a permission, question or decision card may act.
    private var clickGuard = OwnerClickGuard()
    /// What the cards and the rows around them looked like when last laid
    /// out; a change means the cards moved.
    private var cardLayout: [String] = []
    /// Monotonic seconds, for `OwnerClickGuard`.
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// How long the notch stays open when it opened to show the owner
    /// something that is not waiting on them (a failure, a shortcut's move).
    private static let glanceMilliseconds = 4_000
    /// Previews closed with ×, by reply (presentation only).
    private var previewDismissals = ConversationPreviewDismissals()
    private var soundChoice: NotificationSoundChoice = .chime
    private var soundVolume = NotificationSoundVolume.defaultValue

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
    private var compactActivityHideTask: Task<Void, Never>?
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
    private var contextWarnings = ThresholdCrossingTracker()
    private var usageWarnedWindows: Set<String> = []

    var panelSize: CGSize {
        switch panelMode {
        case .compact:
            guard compactActivity != nil else {
                return CGSize(width: islandLayout.compactWidth, height: islandLayout.compactHeight)
            }
            // The strip sits under the camera housing on notched displays,
            // and widens the pill elsewhere; one fixed size either way.
            return islandLayout.hasCameraHousing
                ? CGSize(width: islandLayout.compactWidth, height: islandLayout.compactHeight + CompactActivityStrip.height)
                : CGSize(width: max(islandLayout.compactWidth, CompactActivityStrip.standardWidth), height: islandLayout.compactHeight)
        case .sessions where notchContent == .github:
            return CGSize(
                width: islandLayout.expandedWidth,
                height: islandLayout.expandedContentTopInset + CGFloat(github.density.contentHeight)
            )
        case .sessions where inspectedSession != nil:
            return CGSize(
                width: islandLayout.expandedWidth,
                height: islandLayout.expandedContentTopInset + SessionListLayout.inspectorContentHeight
            )
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
                    + (showsUsageDetails ? usageDetailsHeight : 0)
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
        if let data = defaults.data(forKey: Keys.sessionSounds),
           var stored = try? JSONDecoder().decode(SessionSoundPreferences.self, from: data) {
            stored.prune(now: .now)
            soundPreferences = stored
        }
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

        announceUpdateIfJustInstalled()

        if isUpdateTestMode {
            panelMode = .compact
            updater.start()
            // Scripts/test-local-update.sh --auto runs a whole update without
            // clicks. Only update-test builds (ChimloUpdateTestMode) get here.
            if ProcessInfo.processInfo.arguments.contains("--update-test-auto-install") {
                updater.installAvailableUpdate()
            }
            return
        }

        // NSWorkspace posts its notifications on its own centre, not the
        // default one.
        NSWorkspace.shared.notificationCenter.addObserver(
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
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func openPanel() {
        cancelCollapse()
        panelMode = .sessions
    }

    /// What the open notch shows. Claude wins while it is blocked on the
    /// owner, so a permission request or question is never hidden behind
    /// GitHub; GitHub Mode's place is kept and comes back afterwards.
    var notchContent: NotchContent {
        githubNavigation.effectiveContent(
            claudeNeedsOwner: hasActiveOwnerInteraction,
            gitHubAvailable: github.modeAvailable
        )
    }

    func updateGitHub(_ presentation: GitHubNotchPresentation) {
        guard presentation != github else { return }
        github = presentation
        if !presentation.modeAvailable, githubNavigation.content == .github {
            githubNavigation.returnToClaude()
        }
    }

    /// The GitHub button and ⌃⌥G: open the notch on GitHub Mode, or go back
    /// to Claude when GitHub Mode is already showing.
    func toggleGitHubMode() {
        guard github.modeAvailable else { return }
        if panelMode != .sessions {
            cancelCollapse()
            panelMode = .sessions
            githubNavigation.openGitHub(defaultView: github.defaultView)
        } else {
            githubNavigation.toggle(defaultView: github.defaultView)
        }
        // With a badge on the icon, the click is about that badge: land on
        // the overview, which lists the alerts behind it.
        if githubNavigation.content == .github, GitHubBadge.from(github.indicator) != nil {
            githubNavigation.closeDetail()
            githubNavigation.show(.overview)
        }
        if githubNavigation.content == .github { onGitHubModeOpened?() }
    }

    /// Opens the notch in GitHub Mode on the overview, from the closed
    /// notch's badge.
    func showGitHubAlerts() {
        guard github.modeAvailable else { return }
        cancelCollapse()
        panelMode = .sessions
        if githubNavigation.content != .github { githubNavigation.openGitHub(defaultView: github.defaultView) }
        githubNavigation.closeDetail()
        githubNavigation.show(.overview)
        if githubNavigation.content == .github { onGitHubModeOpened?() }
    }

    func showGitHub(_ view: GitHubView) {
        githubNavigation.show(view)
    }

    func openGitHubDetail(_ detail: GitHubDetail) {
        githubNavigation.open(detail)
    }

    func closeGitHubDetail() {
        githubNavigation.closeDetail()
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
            guard panelMode == .compact,
                  NotchLockPolicy.opens(.hover, isLocked: isNotchLocked, layoutExpandsOnHover: layoutSpec.expandsOnHover)
            else { return }
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

    /// The main update action: install an offer, retry a failure, or check.
    func installUpdate() {
        guard let presentation = updatePresentation else {
            checkForUpdates()
            return
        }
        guard presentation.isActionable else { return }
        cancelCollapse()
        switch presentation.phase {
        case .available: updater.installAvailableUpdate()
        case .failed: updater.retry()
        default: updater.checkForUpdates()
        }
    }

    func checkForUpdates() {
        cancelCollapse()
        updater.checkForUpdates()
    }

    /// A fresh attempt after a failure.
    func retryUpdate() {
        cancelCollapse()
        updater.retry()
    }

    /// Closes the notch's update row. Settings keeps the state; a closed offer
    /// is offered again by the next scheduled check.
    func dismissUpdateNotice() {
        if updatePresentation?.isAvailable == true { updater.dismissOffer() }
        updateNotice.dismiss()
        updateNoticeExpiryTask?.cancel()
        updateNoticeExpiryTask = nil
        syncUpdatePanel()
    }

    /// What the notch's update row shows, if it shows anything.
    var notchUpdatePresentation: AppUpdatePresentation? {
        updateNotice.isVisible(at: .now) ? updateNotice.presentation : nil
    }

    private var preferredIdlePanelMode: PanelMode {
        guard NotchLockPolicy.opens(.updateNotice, isLocked: isNotchLocked) else { return .compact }
        return AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            notice: updateNotice,
            now: .now,
            hasOwnerInteraction: hasActiveOwnerInteraction,
            isOnboarding: panelMode == .onboarding
        ) ? .update : .compact
    }

    private func updatePresentationChanged(_ presentation: AppUpdatePresentation?) {
        if isUpdateTestMode { UpdateTestLog.record(presentation, defaults: defaults) }
        updatePresentation = presentation
        updateNotice.show(presentation, at: .now)
        scheduleUpdateNoticeExpiry()
        syncUpdatePanel()
    }

    /// Moves the idle notch into or out of its update row. An open notch is
    /// left alone; the row appears when it next settles.
    private func syncUpdatePanel() {
        let takesPanel = AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            notice: updateNotice,
            now: .now,
            hasOwnerInteraction: hasActiveOwnerInteraction,
            isOnboarding: panelMode == .onboarding
        )
        if takesPanel {
            guard panelMode == .compact,
                  NotchLockPolicy.opens(.updateNotice, isLocked: isNotchLocked) else { return }
            cancelCollapse()
            showsUsageDetails = false
            panelMode = .update
        } else if panelMode == .update {
            panelMode = .compact
        }
    }

    /// A finished state leaves the notch on its own, so it can never stay.
    private func scheduleUpdateNoticeExpiry() {
        updateNoticeExpiryTask?.cancel()
        updateNoticeExpiryTask = nil
        guard let expiresAt = updateNotice.expiresAt else { return }
        updateNoticeExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            updateNoticeExpiryTask = nil
            objectWillChange.send()
            syncUpdatePanel()
        }
    }

    /// "Updated to 1.0.4" once, on the first launch after an update.
    private func announceUpdateIfJustInstalled() {
        guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return
        }
        let previous = defaults.string(forKey: Keys.lastLaunchedVersion)
        defaults.set(current, forKey: Keys.lastLaunchedVersion)
        guard let version = AppUpdateLaunch.updatedVersion(previous: previous, current: current) else { return }
        updatePresentationChanged(AppUpdatePresentation(phase: .updated(version: version)))
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
        kind: CapacityWindowKind,
        scope: String? = nil
    ) -> CapacityReading {
        let snapshot = capacitySnapshots[provider]
        let window = scope.flatMap { snapshot?.window(kind, scope: $0) } ?? (scope == nil ? snapshot?.window(kind) : nil)
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

    /// The usage panel's rows: the limits Claude Code reported, each with its reading.
    var claudeCapacityRows: [(row: CapacityRow, reading: CapacityReading)] {
        CapacityRows.rows(for: capacitySnapshots[.claude]).map { row in
            (row, capacityReading(provider: .claude, kind: row.kind, scope: row.scope))
        }
    }

    /// The usage panel's height, which follows its row count.
    var usageDetailsHeight: CGFloat {
        CapacityLayout.disclosureHeight(rows: CapacityRows.rows(for: capacitySnapshots[.claude]).count)
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
        let layoutChanged = spec != layoutSpec
        if layoutChanged {
            layoutSpec = spec
            rebuildIslandLayout()
        }
        let showsStrip = settings.showsClosedNotchActivity(at: now, calendar: .current)
        let stripChanged = showsStrip != showsClosedNotchActivity
        if stripChanged {
            showsClosedNotchActivity = showsStrip
            if !showsStrip {
                // Turned off: go at once, not after the between-turns hold.
                compactActivityHideTask?.cancel()
                compactActivityHideTask = nil
                compactActivity = nil
            }
        }
        if layoutChanged || stripChanged { updateCompactActivity() }
        let focus = settings.focus.isActive(at: now, calendar: .current)
        if focus != isFocusModeActive { isFocusModeActive = focus }
        if soundsEnabled != settings.notifications.soundsEnabled {
            soundsEnabled = settings.notifications.soundsEnabled
        }
        if isNotchLocked != settings.notchLocked { isNotchLocked = settings.notchLocked }
        asksAboutUnattendedRuns = settings.askAboutUnattendedRuns
        if preferredDisplay != settings.preferredDisplay { preferredDisplay = settings.preferredDisplay }
        soundChoice = settings.notifications.soundChoice
        soundVolume = settings.notifications.soundVolume
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
            // The trailing wing always carries the Lock Mode glyph beside its
            // other signals (GitHub badge, context, agents), so both wings
            // grow by its width: nothing slides under the camera housing or
            // past the notch's edge.
            wingWidthScale: CGFloat(layoutSpec.compactWingWidthScale) + Self.lockGlyphWingAllowance
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
        let ids = displayedSessions.filter { !$0.isDemo }.map(\.id)
        guard let next = SelectionCycle.next(in: ids, current: selectedSessionID, offset: offset) else { return }
        selectedSessionID = next
        openPanel()
        scheduleCollapseAfterHover(delayMilliseconds: Self.glanceMilliseconds)
    }

    func selectSession(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
    }

    // MARK: Session inspector

    /// The session whose feed is open. Never while Claude waits on the owner:
    /// a permission or question always takes the panel, and the feed comes
    /// back once it is answered.
    var inspectedSession: SessionDisplayModel? {
        guard panelMode == .sessions, notchContent == .claude, !hasActiveOwnerInteraction,
              let inspectedSessionID else { return nil }
        return sessions.first { $0.id == inspectedSessionID }
    }

    func inspect(_ session: SessionDisplayModel) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        selectedSessionID = session.id
        inspectedSessionID = session.id
        cancelCollapse()
    }

    func closeInspector() {
        inspectedSessionID = nil
    }

    /// Brings the session's terminal forward, falling back to its link.
    func focusHost(of session: SessionDisplayModel) {
        if let focusSessionHost { focusSessionHost(session) } else { open(session) }
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
        var decision = attentionDecider?(event) ?? NotificationDecision(
            showInNotch: true,
            expandNotch: kind.priority == .critical,
            playSound: soundsEnabled && kind.priority != .ambient,
            postSystemBanner: false
        )
        // A session's events sound only if its bell is on, once per burst.
        decision.playSound = soundGate.allows(
            kind,
            sessionID: sessionID,
            policyAllows: decision.playSound,
            preferences: soundPreferences,
            now: .now
        )
        return decision
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
                sequence: RequestArithmetic.nextSequence(after: current.lastSequence),
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
                    sequence: RequestArithmetic.nextSequence(after: latest.lastSequence),
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

    /// Ends the tour and takes its demo session with it. The panel is left
    /// to the caller.
    private func closeTour() {
        onboardingTask?.cancel()
        hideExistingDemoSessions()
        onboardingSessionID = nil
        onboardingEvents = []
        defaults.set(true, forKey: Keys.completedOnboarding)
    }

    func finishOnboarding() {
        closeTour()
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
        if soundsEnabled { playSound(cue) }
    }

    /// Every notification sound goes through here: the chosen sound, at the
    /// chosen volume, under the Mac's own volume and mute.
    private func playSound(_ cue: ChiptuneCue) {
        chiptunePlayer.play(cue, choice: soundChoice, volume: soundVolume)
    }

    /// Settings' Preview button: plays even while muted, since it was asked for.
    func previewSound(_ choice: NotificationSoundChoice, volume: Double) {
        chiptunePlayer.play(.success, choice: choice, volume: volume)
    }

    func isSoundEnabled(for sessionID: String) -> Bool {
        soundPreferences.isEnabled(sessionID)
    }

    /// The bell on one session's row. No other session changes. Turning it on
    /// plays the sound once, so the owner hears what to expect.
    func toggleSound(for sessionID: String) {
        let enabled = soundPreferences.toggle(sessionID, at: .now)
        saveSoundPreferences()
        if enabled, soundsEnabled { playSound(.success) }
    }

    private func saveSoundPreferences() {
        if let data = try? JSONEncoder().encode(soundPreferences) {
            defaults.set(data, forKey: Keys.sessionSounds)
        }
    }

    /// Live sessions keep their entries from expiring; checked at most daily.
    private func refreshSoundPreferences(liveSessionIDs: [String]) {
        let stale = liveSessionIDs.contains { id in
            guard let seen = soundPreferences.enabledSessions[id] else { return false }
            return Date.now.timeIntervalSince(seen) > 86_400
        }
        guard stale else { return }
        soundPreferences.touch(liveSessionIDs, at: .now)
        saveSoundPreferences()
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

    /// Whether an owner click on a card may act: it must name the request
    /// (and question step) showing now, and the cards must have held still
    /// long enough to be read (`OwnerClickGuard`). Every card action below
    /// takes the ids the view was showing when it was clicked.
    private func acceptsClick(on requestID: UUID, step: Int = 0) -> Bool {
        clickGuard.accepts(requestID, step: step, at: Self.uptime)
    }

    func respondToPendingDecision(requestID: UUID, approved: Bool) {
        guard pendingDecision?.id == requestID, acceptsClick(on: requestID) else { return }
        finishPendingDecision(outcome: approved ? .approved : .denied, note: nil)
    }

    /// The × on a permission card: Claude Code shows its own prompt in the
    /// terminal instead. Finishing as cancelled makes the hook return no
    /// decision, which never grants anything.
    func handSessionPermissionBackToClaude(sessionID: String, requestID: UUID) {
        guard let request = sessionPermissions[sessionID]?.request,
              request.id == requestID, acceptsClick(on: requestID) else { return }
        finishPermission(requestID: request.id, outcome: .cancelled, note: "Handed back to Claude Code")
    }

    func respondToSessionPermission(
        sessionID: String,
        requestID: UUID,
        outcome: ProviderPermissionOutcome
    ) {
        guard let request = sessionPermissions[sessionID]?.request,
              request.id == requestID, acceptsClick(on: requestID),
              outcome == .allowedOnce
                || outcome == .denied
                // Only where the card offered it (a rule exists that grants
                // no more than the card shows).
                || (outcome == .allowedForSession && request.allowsSessionApproval) else {
            return
        }
        finishPermission(requestID: request.id, outcome: outcome, note: nil)
    }

    /// The question card `sessionID` is showing, when a click on the card
    /// for `requestID` at question `step` may act on it.
    private func clickedQuestion(sessionID: String, requestID: UUID, step: Int) -> SessionQuestionPresentation? {
        guard let presentation = sessionQuestions[sessionID],
              presentation.requestID == requestID, presentation.questionIndex == step,
              acceptsClick(on: requestID, step: step) else { return nil }
        return presentation
    }

    func selectQuestionOption(sessionID: String, requestID: UUID, step: Int, label: String) {
        guard let presentation = clickedQuestion(sessionID: sessionID, requestID: requestID, step: step),
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

    func submitQuestionSelections(sessionID: String, requestID: UUID, step: Int) {
        guard let presentation = clickedQuestion(sessionID: sessionID, requestID: requestID, step: step),
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
    func beginCustomAnswer(sessionID: String, requestID: UUID, step: Int) {
        guard let presentation = clickedQuestion(sessionID: sessionID, requestID: requestID, step: step),
              var flow = questionFlows[presentation.requestID] else { return }
        cancelCollapse()
        flow.isEnteringCustomAnswer = true
        questionFlows[flow.request.id] = flow
        publishQuestion(flow)
    }

    /// Closing the field answers nothing, so it needs no arming delay; it
    /// only has to belong to the question that is showing.
    func cancelCustomAnswer(sessionID: String, requestID: UUID, step: Int) {
        guard let presentation = sessionQuestions[sessionID],
              presentation.requestID == requestID, presentation.questionIndex == step,
              var flow = questionFlows[presentation.requestID] else { return }
        flow.isEnteringCustomAnswer = false
        questionFlows[flow.request.id] = flow
        publishQuestion(flow)
    }

    /// Sends the owner's own words as the answer. Empty or oversized text is
    /// ignored rather than sent, so nothing reaches Claude by accident.
    func submitCustomAnswer(sessionID: String, requestID: UUID, step: Int, text: String) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeQuestionHook.isValidCustomAnswer(answer),
              let presentation = clickedQuestion(sessionID: sessionID, requestID: requestID, step: step),
              var flow = questionFlows[presentation.requestID] else { return }
        flow.answers[flow.currentQuestion.prompt] = answer
        flow.isEnteringCustomAnswer = false
        advanceOrFinish(flow)
    }

    func answerQuestionInClaudeCode(sessionID: String, requestID: UUID, step: Int) {
        guard clickedQuestion(sessionID: sessionID, requestID: requestID, step: step) != nil else { return }
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
        // A session with a card open is never archived out of sight, even
        // when a later event cleared the reducer's own pending request.
        guard !session.isDemo,
              let source = reducer.sessions[session.id],
              source.pendingRequest == nil,
              sessionPermissions[session.id] == nil,
              sessionQuestions[session.id] == nil else { return }

        archivedSessionMarkers[session.id] = SessionArchiveMarker()
        persistArchivedSessionMarkers()
        syncSessionProjections()
    }

    private func receiveLiveEvent(_ event: AgentEvent) {
        hiddenSessionIDs.formUnion(previewSessionIDs)
        recordReceipt(for: event.agent)
        if OwnerInteractionLifetime.endsPendingRequests(event.kind) {
            cancelOwnerInteractions(forEndedSession: event.sessionID)
        }
        if event.kind != .sessionEnded {
            // The session is still talking: a removal scheduled when it
            // looked finished no longer applies.
            sessionRemovalTasks.removeValue(forKey: event.sessionID)?.cancel()
        }
        if event.kind == .sessionEnded {
            previewDismissals.forget(event.sessionID)
            soundGate.forget(event.sessionID)
            if soundPreferences.isEnabled(event.sessionID) {
                soundPreferences.forget(event.sessionID)
                saveSoundPreferences()
            }
        }
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

        let nextSequence = RequestArithmetic.nextSequence(after: reducer.sessions[event.sessionID]?.lastSequence ?? 0)
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
            case .sessionStarted: playSound(.arrival)
            case .permissionRequested, .questionRequested, .failed: playSound(.attention)
            case .activity, .permissionResolved, .questionResolved, .completed, .sessionEnded: break
            }
        }

        if let session = reducer.sessions[event.sessionID],
           sessions.contains(where: { $0.id == event.sessionID }),
           (session.pendingRequest != nil || session.phase == .failed),
           panelMode != .onboarding,
           NotchLockPolicy.opens(session.phase == .failed ? .sessionFailure : .ownerRequest, isLocked: isNotchLocked) {
            cancelCollapse()
            showsUsageDetails = false
            panelMode = .sessions
            // A card keeps the notch open by itself. Without one (a failure)
            // it stays long enough to be read, not half a second.
            scheduleCollapseAfterHover(delayMilliseconds: Self.glanceMilliseconds)
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

    /// The × on a session's prompt-and-reply preview. Hides that preview now
    /// and cancels its timer; the session, its conversation, its history and
    /// any pending request stay exactly as they are, and the notch stays open.
    func dismissConversationPreview(sessionID: String) {
        if let response = reducer.sessions[sessionID]?.latestAgentResponse {
            previewDismissals.dismiss(sessionID: sessionID, response: response)
        }
        completionDetailExpiryTasks.removeValue(forKey: sessionID)?.cancel()
        latestResponseReceivedAt.removeValue(forKey: sessionID)
        syncSessionProjections()
    }

    private func recordLatestResponse(for sessionID: String, receivedAt: Date) {
        // A closed preview stays closed for that reply, whatever repeats.
        let response = reducer.sessions[sessionID]?.latestAgentResponse
        if previewDismissals.isDismissed(sessionID: sessionID, response: response) { return }
        previewDismissals.forget(sessionID)
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
            if soundsEnabled { playSound(.success) }
            return
        }
        let decision = announce(
            .sessionCompleted,
            key: "\(sessionID)|\(response.hashValue)",
            sessionID: sessionID,
            title: bannerTitle(for: sessionID),
            body: "Claude finished and is waiting for you."
        )
        if decision.playSound { playSound(.success) }
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
        if decision.playSound { playSound(cue) }
    }

    /// A context window crossing the attention threshold is worth one
    /// informational nudge per crossing; compaction re-arms it.
    private func announceContextWarnings() {
        for (sessionID, insight) in sessionInsights {
            guard let fraction = insight.contextFraction,
                  contextWarnings.crossed(sessionID, value: fraction, threshold: contextAttentionThreshold),
                  sessions.contains(where: { $0.id == sessionID && !$0.isDemo }) else { continue }
            let percent = Int((fraction * 100).rounded())
            let decision = announce(
                .contextWarning,
                key: sessionID,
                sessionID: sessionID,
                title: bannerTitle(for: sessionID),
                body: "Context is \(percent)% full. Claude Code will compact soon."
            )
            if decision.playSound { playSound(.attention) }
        }
    }

    /// A 5-hour, weekly or per-model weekly limit crossing the warning
    /// threshold, once per limit per reset.
    private func announceUsageWarnings(_ snapshot: ProviderCapacitySnapshot) {
        for window in snapshot.windows {
            let key = "\(window.id)|\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
            let used = window.usedPercentage / 100
            guard used >= usageWarningThreshold, !window.isExpired() else { continue }
            guard usageWarnedWindows.insert(key).inserted else { continue }
            let period = window.kind == .weekly ? "weekly" : "5-hour"
            let name = window.scope.map { "\($0) \(period)" } ?? period
            let decision = announce(
                .usageWarning,
                key: key,
                sessionID: nil,
                title: "Claude usage",
                body: "You have used \(Int(window.usedPercentage.rounded()))% of your \(name) limit."
            )
            if decision.playSound { playSound(.attention) }
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
            let permission = sessionPermissions[session.id]
            let question = sessionQuestions[session.id]
            let runState = SessionRunState.classify(
                phase: session.phase,
                hasOwnerInteraction: permission != nil || question != nil,
                updatedAt: session.updatedAt,
                liveStatus: liveSessions[session.id]?.status,
                now: now
            )
            var mood = mood(for: session)
            // Work that went quiet is not shown as work.
            if mood == .working, runState != .running { mood = .idle }
            return SessionDisplayModel(
                id: session.id,
                agentName: Self.agentName(session.agent),
                title: session.title,
                titleKind: session.titleKind,
                detail: session.detail,
                mood: mood,
                isDemo: isDemo,
                needsAttention: session.pendingRequest != nil
                    || sessionPermissions[session.id] != nil
                    || sessionQuestions[session.id] != nil
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
                live: liveSessions[session.id],
                runState: runState
            )
        }

        // Needs-you, failed, running, waiting for input, recently finished,
        // then older; newest first within each.
        let byID = Dictionary(uniqueKeysWithValues: projectedSessions.map { ($0.id, $0) })
        sessions = SessionOrdering.ordered(projectedSessions.map {
            SessionOrdering.Entry(id: $0.id, state: $0.runState, updatedAt: $0.updatedAt)
        }).compactMap { byID[$0.id] }
        if let inspectedSessionID, byID[inspectedSessionID] == nil {
            self.inspectedSessionID = nil
        }
        noteCardLayout()
        resetSessionRevealIfNoOwnerInteraction()
        updateCompactActivity()
        scheduleSessionActivityExpiry(now: now)
        refreshSoundPreferences(liveSessionIDs: sessions.map(\.id))
    }

    /// Rows changing order or height move the cards under the pointer, so
    /// every card waits again before a click on it counts.
    private func noteCardLayout() {
        let layout = displayedSessions.map { session in
            [
                session.id,
                session.permission?.id.uuidString ?? "",
                session.question.map { "\($0.requestID)#\($0.questionIndex)#\($0.isEnteringCustomAnswer)" } ?? "",
                session.showsCompletedConversation ? "preview" : "",
                showsMetaLine(for: session) ? "meta" : "",
            ].joined(separator: "|")
        }
        guard layout != cardLayout else { return }
        cardLayout = layout
        clickGuard.cardsMoved(at: Self.uptime)
    }

    /// The closed notch's strip: the session that needs the owner, else the
    /// selected or newest running one. Appears at once; disappears only after
    /// a short hold, so two back-to-back turns do not resize the notch.
    private func updateCompactActivity() {
        let line = currentCompactActivityLine()
        if let line {
            compactActivityHideTask?.cancel()
            compactActivityHideTask = nil
            if compactActivity != line { compactActivity = line }
            return
        }
        guard compactActivity != nil, compactActivityHideTask == nil else { return }
        compactActivityHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CompactActivityStrip.hideDelaySeconds))
            guard !Task.isCancelled, let self else { return }
            compactActivityHideTask = nil
            if currentCompactActivityLine() == nil { compactActivity = nil }
        }
    }

    private func currentCompactActivityLine() -> CompactActivityLine? {
        guard showsClosedNotchActivity else { return nil }
        if pendingDecision != nil {
            return CompactActivityLine(tool: nil, text: "Needs your decision", tone: .attention, kind: nil)
        }
        let candidates = sessions.filter { !$0.isDemo }.map {
            NotchActivityFocus.Candidate(id: $0.id, state: $0.runState, updatedAt: $0.updatedAt)
        }
        guard let id = NotchActivityFocus.sessionID(among: candidates, selected: selectedSessionID),
              let session = sessions.first(where: { $0.id == id }) else { return nil }
        return CompactActivityLine.make(
            permissionTool: session.permission?.request.toolName,
            hasQuestion: session.question != nil,
            latest: session.insights?.currentTurnActivity,
            isWorking: session.isRunning,
            fallback: session.detail
        )
    }

    private func scheduleSessionActivityExpiry(now: Date) {
        sessionActivityExpiryTask?.cancel()
        sessionActivityExpiryTask = nil
        // Re-project when a session leaves the list, and when its standing
        // can change with no new evidence (work going stale, a finish no
        // longer recent), so the order and "running" never go out of date.
        let nextExpiration = sessions
            .flatMap { session in
                [
                    SessionVisibilityPolicy.activityLifetime,
                    SessionRunState.idleListingGrace,
                    SessionRunState.staleWorkingAfter,
                    SessionRunState.recentAfter,
                ].map { session.updatedAt.addingTimeInterval($0 + 1) }
            }
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
        // Only sessions still known keep their insights, so a long-running
        // app does not carry (and re-compare) every session it ever saw.
        merged = merged.filter { reducer.sessions[$0.key] != nil || insights[$0.key] != nil }
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
                // While usage is on screen (the open notch, the companion's
                // usage card), keep it fresh. The probe runs only when the
                // saved numbers are over five minutes old, and backs off
                // after a failure (CapacityPolicy.shouldProbeClaudeUsage).
                if showsUsageDetails || panelMode == .sessions || isShowingUsageInCompanion {
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
        // The status line reports no per-model limits. Keep the ones the
        // /usage panel found until they reset, and save them with the new
        // reading so a relaunch keeps them too.
        let merged = snapshot.keepingModelLimits(from: capacitySnapshots[.claude])
        receiveCapacity(merged, persist: merged != snapshot)
    }

    /// Room for the lock glyph and its spacing in the closed notch's trailing
    /// wing, as a fraction of the 32-point base wing (about 14 points).
    private static let lockGlyphWingAllowance: CGFloat = 0.45

    /// Usage cards in the companion window that are on screen.
    private var usageViewers = 0
    /// The companion window itself is open. Closing a window does not tell
    /// its views they disappeared, so the cards alone cannot say that nobody
    /// is looking any more.
    private var isCompanionWindowOpen = false

    private var isShowingUsageInCompanion: Bool {
        isCompanionWindowOpen && usageViewers > 0
    }

    /// The companion window opened or closed; set by its coordinator.
    func companionWindowChanged(isOpen: Bool) {
        guard isCompanionWindowOpen != isOpen else { return }
        isCompanionWindowOpen = isOpen
        if isShowingUsageInCompanion { refreshClaudeCapacityFromCLIIfNeeded() }
    }

    /// A companion usage card appeared: count it, and freshen old numbers.
    func usageCardAppeared() {
        usageViewers += 1
        refreshClaudeCapacityFromCLIIfNeeded()
    }

    func usageCardDisappeared() {
        usageViewers = max(0, usageViewers - 1)
    }

    private func refreshClaudeCapacityFromCLIIfNeeded() {
        let now = Date.now
        guard claudeUsageRefreshTask == nil,
              CapacityPolicy.shouldProbeClaudeUsage(
                // Per-model limits come only from this probe, so their age
                // counts even while the status line keeps the rest fresh.
                snapshot: capacitySnapshots[.claude]?.datedByOldestLimit,
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
        // A card still waiting on the owner keeps its session in the notch;
        // look again once it may have been answered.
        guard sessionPermissions[sessionID] == nil, sessionQuestions[sessionID] == nil else {
            scheduleSessionRemoval(sessionID)
            return
        }
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
        guard !Task.isCancelled else {
            return ChimloDecisionResponse(requestID: request.id, outcome: .cancelled, note: Self.stoppedWaitingNote)
        }
        endTourForRealRequest()

        // The transport cancels this task when the helper's connection
        // closes; the request then leaves the notch without an answer.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancelCollapse()
                showsAllSessionsDuringOwnerInteraction = false
                pendingDecision = request
                decisionContinuation = continuation
                clickGuard.presented(request.id, at: Self.uptime)
                if NotchLockPolicy.opens(.ownerRequest, isLocked: isNotchLocked) {
                    showsUsageDetails = false
                    panelMode = .sessions
                }
                scheduleDecisionExpiry(for: request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, pendingDecision?.id == request.id else { return }
                finishPendingDecision(outcome: .cancelled, note: Self.stoppedWaitingNote)
            }
        }
    }

    /// A real request outranks the setup tour: the tour ends (its demo
    /// session goes with it) so the notch never shows a fake "WAIT" beside
    /// the real one.
    private func endTourForRealRequest() {
        guard onboardingSessionID != nil || panelMode == .onboarding else { return }
        finishOnboarding()
    }

    /// Why a request left the notch when Claude Code ended its hook.
    private static let stoppedWaitingNote = "Claude Code stopped waiting for an answer"
    private static let unattendedRunNote = "Unattended run: left to Claude Code"

    /// A session that ended takes its open requests with it. Its hooks are
    /// gone, so nothing is waiting for an answer any more.
    private func cancelOwnerInteractions(forEndedSession sessionID: String) {
        for (id, request) in permissionRequests where request.sessionID == sessionID {
            finishPermission(requestID: id, outcome: .cancelled, note: Self.stoppedWaitingNote)
        }
        for (id, flow) in questionFlows where flow.request.sessionID == sessionID {
            finishQuestion(requestID: id, outcome: .cancelled, answers: [:], note: Self.stoppedWaitingNote)
        }
    }

    private func requestPermission(
        _ request: ProviderPermissionRequest
    ) async -> ProviderPermissionResponse {
        if let expiresAt = request.expiresAt, expiresAt <= Date() {
            return .unavailable(for: request.id, reason: "Permission request expired")
        }
        // A run nobody is watching: Claude Code decides, as it does without
        // the notch, unless the owner asked to hear about these. Answered
        // before anything is stored, so no card, sound or session change.
        guard UnattendedRunPolicy.reachesNotch(
            isUnattended: request.isUnattended,
            ownerAsksAboutUnattendedRuns: asksAboutUnattendedRuns
        ) else {
            return .unavailable(for: request.id, reason: Self.unattendedRunNote)
        }
        guard request.agent == .claude,
              !request.sessionID.isEmpty,
              !request.toolName.isEmpty,
              !request.prompt.isEmpty,
              sessionPermissions[request.sessionID] == nil,
              sessionQuestions[request.sessionID] == nil else {
            return .unavailable(
                for: request.id,
                reason: "This session already has a pending owner interaction"
            )
        }
        guard !Task.isCancelled else {
            return ProviderPermissionResponse(requestID: request.id, outcome: .cancelled, note: Self.stoppedWaitingNote)
        }
        endTourForRealRequest()

        // Claude Code stopped waiting (answered in the terminal, interrupted
        // the turn, ended the session): the transport cancels this task and
        // the card goes, granting nothing.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancelCollapse()
                showsAllSessionsDuringOwnerInteraction = false
                permissionRequests[request.id] = request
                permissionContinuations[request.id] = continuation
                clickGuard.presented(request.id, at: Self.uptime)
                sessionPermissions[request.sessionID] = SessionPermissionPresentation(request: request)
                presentPermissionEvent(for: request)
                if NotchLockPolicy.opens(.ownerRequest, isLocked: isNotchLocked) {
                    showsUsageDetails = false
                    panelMode = .sessions
                }
                schedulePermissionExpiry(for: request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPermission(requestID: request.id, outcome: .cancelled, note: Self.stoppedWaitingNote)
            }
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
        let nanoseconds = RequestArithmetic.sleepNanoseconds(for: expiresAt.timeIntervalSinceNow)
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
        clickGuard.removed(requestID, at: Self.uptime)
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
                    sequence: RequestArithmetic.nextSequence(after: current.lastSequence),
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
        // As for permissions: an unattended run's question stays with
        // Claude Code unless the owner asked to hear about these.
        guard UnattendedRunPolicy.reachesNotch(
            isUnattended: request.isUnattended,
            ownerAsksAboutUnattendedRuns: asksAboutUnattendedRuns
        ) else {
            return .unavailable(for: request.id, reason: Self.unattendedRunNote)
        }
        guard !request.questions.isEmpty,
              request.questions.allSatisfy({ !$0.prompt.isEmpty && !$0.options.isEmpty }),
              sessionQuestions[request.sessionID] == nil,
              sessionPermissions[request.sessionID] == nil else {
            return .unavailable(for: request.id, reason: "This session already has a pending question")
        }
        guard !Task.isCancelled else {
            return ProviderQuestionResponse(requestID: request.id, outcome: .cancelled, answers: [:], note: Self.stoppedWaitingNote)
        }
        endTourForRealRequest()

        // As for permissions: when Claude Code ends the hook, the question
        // leaves the notch unanswered.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancelCollapse()
                showsAllSessionsDuringOwnerInteraction = false
                let flow = QuestionFlow(request: request)
                questionFlows[request.id] = flow
                questionContinuations[request.id] = continuation
                clickGuard.presented(request.id, step: flow.questionIndex, at: Self.uptime)
                publishQuestion(flow)
                presentQuestionEvent(for: flow)
                if NotchLockPolicy.opens(.ownerRequest, isLocked: isNotchLocked) {
                    showsUsageDetails = false
                    panelMode = .sessions
                }
                scheduleQuestionExpiry(for: request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishQuestion(requestID: request.id, outcome: .cancelled, answers: [:], note: Self.stoppedWaitingNote)
            }
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
            // The next question takes the place of the one just answered: it
            // waits like a new card, so a double-click cannot answer it unread.
            clickGuard.presented(next.request.id, step: next.questionIndex, at: Self.uptime)
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
        let nanoseconds = RequestArithmetic.sleepNanoseconds(for: expiresAt.timeIntervalSinceNow)
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
        clickGuard.removed(requestID, at: Self.uptime)
        questionExpiryTasks.removeValue(forKey: requestID)?.cancel()
        sessionQuestions.removeValue(forKey: flow.request.sessionID)

        if let current = reducer.sessions[flow.request.sessionID] {
            consume(
                AgentEvent(
                    sessionID: current.id,
                    sequence: RequestArithmetic.nextSequence(after: current.lastSequence),
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
        let nanoseconds = RequestArithmetic.sleepNanoseconds(for: expiresAt.timeIntervalSinceNow)
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
        clickGuard.removed(request.id, at: Self.uptime)
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
        static let sessionSounds = "overhead.sound.sessions"
        static let lastLaunchedVersion = "overhead.update.lastLaunchedVersion"
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

/// Records each update state for the local update test, so it can check the
/// whole lifecycle across the relaunch. Update-test builds only; the path is
/// remembered from the first launch's argument and must be the test's log.
private enum UpdateTestLog {
    private static let pathKey = "overhead.updateTest.logPath"

    static func record(_ presentation: AppUpdatePresentation?, defaults: UserDefaults) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--update-test-log"), index + 1 < arguments.count {
            defaults.set(arguments[index + 1], forKey: pathKey)
        }
        guard let path = defaults.string(forKey: pathKey),
              path.hasSuffix("/update-test/states.log") else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let phase = presentation.map { "\($0.phase)" } ?? "none"
        let line = "\(version)\t\(phase)\t\(presentation?.statusText ?? "")\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

