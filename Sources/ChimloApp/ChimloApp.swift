import AppKit
import ChimloCore
import SwiftUI

@main
struct ChimloApplication: App {
    @NSApplicationDelegateAdaptor(ChimloAppDelegate.self) private var appDelegate

    init() {
        // The release check: draw a release's What's New and exit, without
        // starting the app (see WhatsNewRenderCheck).
        WhatsNewRenderCheck.runIfRequested()
    }

    var body: some Scene {
        Settings {
            ChimloSettingsView(model: appDelegate.model)
                .frame(minWidth: 640, minHeight: 440)
        }
    }
}

@MainActor
final class ChimloAppDelegate: NSObject, NSApplicationDelegate {
    let model = ApplicationModel()
    private lazy var services = OverheadServices(model: model)
    private var islandCoordinator: IslandWindowCoordinator?
    private var settingsCoordinator: SettingsWindowCoordinator?
    private var companionCoordinator: CompanionWindowCoordinator?
    private var setupCoordinator: SetupCoordinator?
    private var whatsNewCoordinator: WhatsNewCoordinator?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsCoordinator = SettingsWindowCoordinator(model: model)
        self.settingsCoordinator = settingsCoordinator

        let whatsNewCoordinator = WhatsNewCoordinator(model: model)
        self.whatsNewCoordinator = whatsNewCoordinator
        model.presentWhatsNew = { [weak whatsNewCoordinator] subject in
            whatsNewCoordinator?.show(subject)
        }

        if model.isUpdateTestMode {
            model.start()
            settingsCoordinator.show()
            return
        }

        let companion = CompanionWindowCoordinator(services: services)
        companionCoordinator = companion
        services.openCompanion = { [weak companion] section, pane in
            companion?.show(section, settingsPane: pane)
        }
        let islandCoordinator = IslandWindowCoordinator(
            model: model,
            github: services.github,
            openSettings: { [weak companion] in companion?.show(.settings) }
        )
        self.islandCoordinator = islandCoordinator

        let setupCoordinator = SetupCoordinator(model: model)
        self.setupCoordinator = setupCoordinator
        setupCoordinator.onFinish = { [weak self] revealNotch in
            self?.setupFinished(revealNotch: revealNotch)
        }
        model.presentSetup = { [weak self, weak setupCoordinator] fromWelcome in
            guard let self, let setupCoordinator else { return }
            setupCoordinator.present(fromWelcome ? .fromWelcome(self.welcomeFlow()) : .reconnect)
        }

        // The model starts first: setup's verification pings its listener.
        model.start()
        services.start()
        if let flow = SetupFlow.atLaunch(
            hasCompletedSetup: model.hasCompletedSetup,
            integrationInstalled: model.claudeConnectionState.isInstalled,
            integrationNeedsRepair: model.claudeConnectionState == .needsRepair
        ) {
            // The notch waits for setup, so nobody's first sight is an empty,
            // disconnected island next to a window telling them to connect.
            setupCoordinator.present(.fromWelcome(flow))
        } else {
            islandCoordinator.show()
        }
    }

    private func welcomeFlow() -> SetupFlow {
        // A replay always starts at the welcome, whatever was completed before.
        SetupFlow.atLaunch(
            hasCompletedSetup: false,
            integrationInstalled: model.claudeConnectionState.isInstalled,
            integrationNeedsRepair: model.claudeConnectionState == .needsRepair
        ) ?? .reconnecting(integrationNeedsRepair: false)
    }

    /// The setup window closed, finished or not. The notch takes over: open
    /// once on the owner's real sessions after "See your notch", otherwise
    /// closed, where its own Connect button resumes setup.
    private func setupFinished(revealNotch: Bool) {
        islandCoordinator?.show()
        if revealNotch { model.revealNotchAfterSetup() }
    }

    /// Opening the app again while it runs (Finder, Spotlight, `open`) shows
    /// the companion window, the way a Mac app shows its main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        companionCoordinator?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        islandCoordinator?.stop()
        services.stop()
        model.stop()
        islandCoordinator = nil
        settingsCoordinator = nil
    }
}
