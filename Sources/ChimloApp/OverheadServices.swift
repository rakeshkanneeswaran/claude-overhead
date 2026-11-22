import AppKit
import ChimloCore
import Combine
import Foundation

/// Owns the app's long-lived services and the wiring between them, so the
/// notch model stays about sessions and every setting has one place where it
/// takes effect.
@MainActor
final class OverheadServices: ObservableObject {
    let model: ApplicationModel
    let settings: SettingsModel
    let history: HistoryModel
    let github: GitHubModel
    let attention: AttentionRouter
    let folderAccess = FolderAccessModel()
    let notifier = SystemNotifier()
    private let hotKeys = GlobalHotKeys()

    /// Shortcuts that another app or macOS already owns.
    @Published private(set) var unavailableShortcuts: Set<ShortcutAction> = []
    @Published private(set) var bannerAuthorization: SystemNotifier.Authorization = .notDetermined
    @Published private(set) var loginItemProblem: String?

    /// Opens the companion window; set by the app delegate.
    var openCompanion: ((CompanionSection, SettingsPane?) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var clockTask: Task<Void, Never>?
    private var hasStarted = false

    init(model: ApplicationModel, settings: SettingsModel = SettingsModel()) {
        self.model = model
        self.settings = settings
        history = HistoryModel(settings: settings.settings, folderAccess: folderAccess)
        github = GitHubModel(folderAccess: folderAccess)
        let settingsModel = settings
        attention = AttentionRouter(notifier: notifier, settings: { settingsModel.settings })
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        model.attentionDecider = { [weak self] event in
            guard let self else { return .suppressed }
            return attention.route(event)
        }
        notifier.onActivate = { [weak self] in
            self?.model.openPanel()
        }
        github.projectPaths = { [weak self] in
            guard let self else { return [] }
            return model.sessions.compactMap(\.projectPath) + history.recentProjectPaths()
        }
        github.onEvent = { [weak self] event in
            guard let self else { return }
            let decision = attention.route(event)
            if decision.playSound { model.playCue(.attention) }
        }

        model.toggleFocusMode = { [weak self] in
            self?.settings.settings.focus.isOn.toggle()
        }
        model.focusSessionHost = { [weak self] session in
            self?.focusHost(of: session)
        }
        wireGitHub()
        settings.onChange = { [weak self] old, new in
            self?.apply(new, previous: old)
        }
        apply(settings.settings, previous: nil)

        // The notch's own mute button writes the model; mirror it back so the
        // setting and the button never disagree.
        model.$soundsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, settings.settings.notifications.soundsEnabled != enabled else { return }
                settings.settings.notifications.soundsEnabled = enabled
            }
            .store(in: &cancellables)


        history.start()
        model.$sessions
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] sessions in self?.history.observe(sessions) }
            .store(in: &cancellables)

        // Focus and quiet-hour schedules change with the clock, not with a
        // setting, so the notch re-reads them once a minute.
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                model.applySettings(settings.settings)
            }
        }
        Task { bannerAuthorization = await notifier.authorization() }
    }

    func stop() {
        clockTask?.cancel()
        clockTask = nil
        _ = hotKeys.replace(with: [])
        github.stop()
        history.stop()
    }

    // MARK: GitHub

    /// GitHub data flows one way: GitHubModel → this presentation → the
    /// notch. The selection's single home is the settings; GitHubModel and
    /// the settings pane both write it there.
    private func wireGitHub() {
        github.saveSelection = { [weak self] selection in
            guard let self, settings.settings.github.selection != selection else { return }
            settings.settings.github.selection = selection
        }
        model.githubNavigation.restore(view: settings.settings.github.lastView)
        model.onGitHubModeOpened = { [weak self] in self?.github.markViewed() }
        github.saveMergeMethod = { [weak self] repositoryID, method in
            guard let self, settings.settings.github.mergeMethods[String(repositoryID)] != method else { return }
            settings.settings.github.mergeMethods[String(repositoryID)] = method
        }
        model.openGitHubIntegration = { [weak self] in
            guard let self else { return }
            github.companionRequest = .tab(.integration)
            openCompanion?(.github, nil)
        }
        model.openGitHubInCompanion = { [weak self] detail in
            guard let self else { return }
            github.companionRequest = detail.map(GitHubPageRequest.detail)
            openCompanion?(.github, nil)
        }
        Publishers.MergeMany(
            github.$snapshots.map { _ in () }.eraseToAnyPublisher(),
            github.$connection.map { _ in () }.eraseToAnyPublisher(),
            github.$reviewRequests.map { _ in () }.eraseToAnyPublisher(),
            github.$lastViewed.map { _ in () }.eraseToAnyPublisher(),
            github.$dismissals.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refreshGitHubPresentation() }
        .store(in: &cancellables)
        // Remember the tab for "Where I left off", across restarts.
        model.$githubNavigation
            .map(\.view)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] view in
                guard let self, settings.settings.github.lastView != view else { return }
                settings.settings.github.lastView = view
            }
            .store(in: &cancellables)
    }

    private func refreshGitHubPresentation() {
        let preferences = settings.settings.github
        model.updateGitHub(GitHubNotchPresentation(
            modeAvailable: preferences.enabled && preferences.notchModeEnabled,
            showsButton: preferences.showsNotchButton,
            indicator: github.indicator,
            showsInClosedNotch: preferences.enabled && preferences.showInClosedNotch,
            density: preferences.density,
            defaultView: preferences.defaultView,
            showsAccount: preferences.showAccount,
            showsRepositoryInfo: preferences.showRepositoryInfo,
            showsDetailedMetadata: preferences.showDetailedMetadata,
            allowsMerging: preferences.allowMerging
        ))
    }

    // MARK: Settings

    private func apply(_ new: OverheadSettings, previous: OverheadSettings?) {
        model.applySettings(new)
        history.applySettings(new, previous: previous)
        github.apply(new.github)
        refreshGitHubPresentation()

        if previous?.shortcuts != new.shortcuts || previous?.shortcutsEnabled != new.shortcutsEnabled {
            registerShortcuts(new)
        }
        if let previous, previous.launchAtLogin != new.launchAtLogin {
            let result = LoginItem.setEnabled(new.launchAtLogin)
            loginItemProblem = result == new.launchAtLogin
                ? nil
                : "macOS did not change Login Items. Check System Settings → General → Login Items."
        }
        // macOS asks for banner permission only when the owner turns a
        // banner on, never at launch.
        if let previous, !previous.notifications.wantsBanners, new.notifications.wantsBanners {
            Task { bannerAuthorization = await notifier.requestAuthorization() }
        }
    }

    /// Launch at login as macOS reports it, which the owner can also change
    /// in System Settings.
    var launchesAtLogin: Bool { LoginItem.isEnabled }

    func refreshBannerAuthorization() {
        Task { bannerAuthorization = await notifier.authorization() }
    }

    func requestBannerAuthorization() {
        Task { bannerAuthorization = await notifier.requestAuthorization() }
    }

    private func registerShortcuts(_ settings: OverheadSettings) {
        guard settings.shortcutsEnabled else {
            _ = hotKeys.replace(with: [])
            unavailableShortcuts = []
            return
        }
        let actions = ShortcutAction.allCases
        var bindings: [GlobalHotKeys.Binding] = []
        for (index, action) in actions.enumerated() {
            guard let combo = settings.shortcuts[action] else { continue }
            bindings.append(GlobalHotKeys.Binding(
                id: UInt32(index + 1),
                keyCode: combo.keyCode,
                command: combo.modifiers.contains(.command),
                option: combo.modifiers.contains(.option),
                control: combo.modifiers.contains(.control),
                shift: combo.modifiers.contains(.shift),
                action: { [weak self] in self?.perform(action) }
            ))
        }
        let failed = hotKeys.replace(with: bindings)
        unavailableShortcuts = Set(failed.compactMap { id in
            let index = Int(id) - 1
            return actions.indices.contains(index) ? actions[index] : nil
        })
    }

    // MARK: Actions

    func perform(_ action: ShortcutAction) {
        switch action {
        case .togglePanel:
            if model.panelMode == .sessions {
                model.collapsePanelFromOutsideClick()
            } else {
                model.openPanel()
            }
        case .showSessions:
            openCompanion?(.sessions, nil)
        case .nextSession:
            model.selectSession(offset: 1)
        case .previousSession:
            model.selectSession(offset: -1)
        case .focusTerminal:
            if let session = model.focusTargetSession { focusHost(of: session) }
        case .openHistory:
            openCompanion?(.history, nil)
        case .toggleFocusMode:
            settings.settings.focus.isOn.toggle()
        case .toggleGitHubMode:
            model.toggleGitHubMode()
        case .openSettings:
            openCompanion?(.settings, nil)
        }
    }

    /// Brings the terminal tab or editor window running a session forward.
    func focusHost(of session: SessionDisplayModel) {
        let path = session.projectPath
        Task {
            if let host = await SessionHostService.resolve(projectPath: path),
               await SessionHostService.focus(host) {
                return
            }
            model.open(session)
        }
    }

    /// Resumes a finished session in a new Terminal window with
    /// `claude --resume`, after the owner asked for it.
    func resume(sessionID: String, projectPath: String?) async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = ClaudeCodeLocator.executableCandidates(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            path: environment["PATH"]
        ).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        return await SessionHostService.resumeInTerminal(
            sessionID: sessionID,
            projectPath: projectPath,
            claudeExecutable: executable
        )
    }

    /// Today's GitHub activity for the recap, when GitHub is on.
    var recapGitHubInput: RecapGitHubInput? {
        guard settings.settings.github.enabled, github.connection.isConnected else { return nil }
        var input = github.todayCounts
        input.reviewsWaiting = github.reviewRequests.count
        return input
    }
}

extension NotificationPreferences {
    /// Whether any event is set to post a macOS banner.
    var wantsBanners: Bool {
        OverheadEventKind.allCases.contains { preference(for: $0).enabled && preference(for: $0).systemBanner }
    }
}
