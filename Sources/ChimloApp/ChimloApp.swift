import AppKit
import ChimloCore
import SwiftUI

@main
struct ChimloApplication: App {
    @NSApplicationDelegateAdaptor(ChimloAppDelegate.self) private var appDelegate

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

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsCoordinator = SettingsWindowCoordinator(model: model)
        self.settingsCoordinator = settingsCoordinator

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
            openSettings: { [weak companion] in companion?.show(.settings) }
        )
        self.islandCoordinator = islandCoordinator

        let setupCoordinator = SetupCoordinator(model: model)
        self.setupCoordinator = setupCoordinator
        setupCoordinator.onFinish = { [weak self] showPreview in
            self?.setupFinished(showPreview: showPreview)
        }
        model.presentSetup = { [weak self, weak setupCoordinator] fromWelcome in
            guard let self, let setupCoordinator else { return }
            setupCoordinator.present(fromWelcome ? .fromWelcome(self.welcomeFlow()) : .reconnect)
        }

        // The model starts first: setup's verification pings its listener.
        model.start()
        services.start()
        // SNAPSHOT-HOOK (temporary, removed after verification)
        if let raw = ProcessInfo.processInfo.environment["OVERHEAD_SNAPSHOT_SECTION"] {
            let parts = raw.split(separator: ":").map(String.init)
            if let section = CompanionSection(rawValue: parts[0]) {
                companion.show(section, settingsPane: parts.count > 1 ? SettingsPane(rawValue: parts[1]) : nil)
            }
        }
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

    /// The setup window closed, finished or not. The notch takes over: with
    /// its preview after a verified connection, otherwise idle, where its own
    /// Connect button resumes setup.
    private func setupFinished(showPreview: Bool) {
        islandCoordinator?.show()
        if showPreview { model.beginOnboardingDemo() }
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
