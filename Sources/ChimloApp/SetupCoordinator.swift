import AppKit
import ChimloCore
import SwiftUI

/// Where a setup window starts.
enum SetupEntry {
    /// First launch, or "Run setup again": the full journey from the welcome.
    case fromWelcome(SetupFlow)
    /// Later, from the notch: straight to what connecting changes.
    case reconnect
}

/// Owns the setup window and does the real work behind each screen: finding
/// Claude Code, connecting through `AgentIntegrationManager` (the same path
/// Settings uses), and verifying the result end to end. Screens read `flow`
/// and call these methods; the rules for moving between screens live in
/// `SetupFlow`, where they are tested.
@MainActor
final class SetupCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let installGuideURL = URL(string: "https://code.claude.com/docs/en/setup")

    @Published private(set) var flow = SetupFlow.reconnecting(integrationNeedsRepair: false)
    /// The exact settings file a connect would write, for "Show the exact changes".
    @Published private(set) var settingsPreview: String?

    /// Runs when the window closes. `showPreview` is true when the owner chose
    /// "See your notch" after a verified connection.
    var onFinish: ((_ showPreview: Bool) -> Void)?

    let model: ApplicationModel
    private let integration = AgentIntegrationManager.live()
    private var window: NSWindow?
    private var detectTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var closesIntoPreview = false

    init(model: ApplicationModel) {
        self.model = model
    }

    func present(_ entry: SetupEntry) {
        // A visible window keeps its place, so a second click never resets a
        // connection that is still running.
        if window?.isVisible != true {
            switch entry {
            case let .fromWelcome(flow):
                self.flow = flow
            case .reconnect:
                flow = .reconnecting(integrationNeedsRepair: model.claudeConnectionState == .needsRepair)
            }
            settingsPreview = nil
        }
        showWindow()
    }

    // MARK: Screen actions

    func getStarted() {
        withAnimation(SetupMotion.screen) { flow.getStarted() }
        detectClaudeCode()
    }

    func detectClaudeCode() {
        detectTask?.cancel()
        flow.detectionStarted()
        detectTask = Task { [weak self] in
            let started = Date.now
            let result = await Task.detached { Self.detection() }.value
            await Self.hold(since: started)
            guard !Task.isCancelled, let self else { return }
            withAnimation(SetupMotion.state) { flow.detectionFinished(result) }
        }
    }

    func continueToExplain() {
        withAnimation(SetupMotion.screen) { flow.continueToExplain() }
    }

    func back() {
        withAnimation(SetupMotion.screen) { flow.back() }
        if flow.step == .findClaudeCode, flow.detection == .checking {
            detectClaudeCode()
        }
    }

    /// Connects, or re-verifies an existing connection from the welcome.
    func connect() {
        guard connectTask == nil else { return }
        var next = flow
        guard next.beginConnecting() else { return }
        withAnimation(SetupMotion.screen) { flow = next }
        connectTask = Task { [weak self] in
            await self?.runConnection()
            self?.connectTask = nil
        }
    }

    func showSettingsPreview() {
        let integration = integration
        Task { [weak self] in
            let text = await Task.detached { () -> String in
                do {
                    return try integration.preview(for: .claude)
                } catch {
                    return "Overhead can't read your Claude Code settings: \(error.localizedDescription)"
                }
            }.value
            withAnimation(SetupMotion.state) { self?.settingsPreview = text }
        }
    }

    func hideSettingsPreview() {
        withAnimation(SetupMotion.state) { settingsPreview = nil }
    }

    func openInstallGuide() {
        guard let url = Self.installGuideURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// "Not now", "Set up later", or the close button. Setup stays unfinished,
    /// so it resumes at the next launch; the notch keeps its own Connect button.
    func notNow() {
        window?.close()
    }

    func seeYourNotch() {
        closesIntoPreview = true
        window?.close()
    }

    // MARK: Connecting

    private func runConnection() async {
        let integration = integration

        // 1. Find Claude Code again: it may have moved since the welcome.
        var started = Date.now
        let detection = await Task.detached { Self.detection() }.value
        await Self.hold(since: started)
        guard case let .found(installation) = detection else {
            if case let .failed(reason) = detection {
                fail(.checkingClaudeCode, "Your Claude Code settings need attention first.", reason)
            } else {
                fail(
                    .checkingClaudeCode,
                    "Claude Code isn't installed on this Mac, so there's nothing to connect yet.",
                    "No claude executable, editor extension, or ~/.claude folder was found."
                )
            }
            return
        }
        advance(.checkingClaudeCode, "Found the \(installation.summary).")

        // 2. The helper that Claude Code's hooks run.
        started = Date.now
        do {
            _ = try await Task.detached { try integration.prepareStableHelper() }.value
        } catch {
            await Self.hold(since: started)
            fail(.preparingHelper, "Overhead couldn't install its helper.", error.localizedDescription)
            return
        }
        await Self.hold(since: started)
        advance(.preparingHelper, "Installed in ~/Library/Application Support/Overhead.")

        // 3. Claude Code's settings: the same marker-scoped merge, backup, and
        //    validation that Settings uses. An unchanged file is not rewritten.
        started = Date.now
        let settingsURL = integration.claudeSettingsURL
        let before = try? Data(contentsOf: settingsURL)
        let report: AgentIntegrationManager.ConnectionReport
        do {
            report = try await Task.detached { try integration.connect(.claude) }.value
        } catch {
            await Self.hold(since: started)
            let after = try? Data(contentsOf: settingsURL)
            if after != before {
                // Written but not confirmed: remove only Overhead's entries.
                try? await Task.detached { try integration.disconnect(.claude) }.value
            }
            model.refreshAgentConnections()
            fail(.updatingSettings, Self.settingsFailureMessage(for: error), error.localizedDescription)
            return
        }
        await Self.hold(since: started)
        model.refreshAgentConnections()
        let settingsResult = switch (report.changedSettings, report.createdBackup) {
        case (false, _): "Already up to date. Nothing was rewritten."
        case (true, .some): "Hooks added. Your original file is saved as settings.json.overhead-backup."
        case (true, .none): "Hooks added. Everything else in the file is unchanged."
        }
        advance(.updatingSettings, settingsResult)

        // 4. Verify end to end: the settings re-read as current, and the exact
        //    helper Claude Code will run reaches the app over its local channel.
        started = Date.now
        let state = integration.status(for: .claude, lastReceiptAt: nil)
        guard state.isInstalled else {
            await Self.hold(since: started)
            fail(
                .verifying,
                "The settings were written, but Overhead's hooks don't read back as expected.",
                "Connection state after writing: \(state)"
            )
            return
        }
        let pingFailure = await Self.pingHelper(at: integration.stableHelperURL)
        await Self.hold(since: started)
        if let pingFailure {
            fail(
                .verifying,
                "The hooks are in place, but the helper couldn't reach Claude Overhead. Quit and reopen the app, then try again.",
                pingFailure
            )
            return
        }
        withAnimation(SetupMotion.screen) {
            flow.connectionVerified(result: "The helper reached Claude Overhead.")
        }
        model.markSetupCompleted()
        model.playCue(.success)
    }

    private func advance(_ stage: SetupStage, _ result: String) {
        withAnimation(SetupMotion.state) { flow.stageFinished(stage, result: result) }
    }

    private func fail(_ stage: SetupStage, _ message: String, _ details: String) {
        withAnimation(SetupMotion.screen) {
            flow.connectionFailed(SetupFailure(stage: stage, message: message, details: details))
        }
        model.playCue(.attention)
    }

    private static func settingsFailureMessage(for error: Error) -> String {
        switch error {
        case is ClaudeHookConfigurationError, is ClaudeStatusLineConfigurationError:
            "Your Claude Code settings file isn't in a shape Overhead can safely edit, so it was left as it was."
        case is CocoaError:
            "macOS didn't let Overhead write to ~/.claude/settings.json."
        default:
            "Overhead couldn't update Claude Code's settings, so it removed its own changes."
        }
    }

    /// Finds Claude Code, then checks that its settings file, if any, is JSON
    /// Overhead can merge into. A broken file is a real blocker, so it is
    /// reported here instead of failing later in the middle of connecting.
    nonisolated private static func detection() -> SetupFlow.Detection {
        guard let installation = ClaudeCodeLocator.detect() else { return .notFound }
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: settings), !data.isEmpty,
           (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil {
            return .failed(
                "~/.claude/settings.json isn't valid JSON. Fix it (or move it aside), then check again."
            )
        }
        return .found(installation)
    }

    /// Real work can finish in milliseconds. Each stage stays on screen long
    /// enough to read; this paces the presentation, it never fakes the work.
    private static func hold(since start: Date, minimum: TimeInterval = 0.55) async {
        let remaining = minimum - Date.now.timeIntervalSince(start)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
    }

    /// Runs `<helper> ping`, the same binary at the same path Claude Code's
    /// hooks call. Returns nil on success, otherwise what went wrong.
    nonisolated private static func pingHelper(at helper: URL) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            let process = Process()
            let errors = Pipe()
            process.executableURL = helper
            process.arguments = ["ping"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            process.terminationHandler = { finished in
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                once.resume(finished.terminationStatus == 0
                    ? nil
                    : (message.isEmpty ? "The helper exited with status \(finished.terminationStatus)." : message))
            }
            do {
                try process.run()
            } catch {
                once.resume("The helper couldn't start: \(error.localizedDescription)")
                return
            }
            let processID = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.resume("The helper didn't answer within 5 seconds.") {
                    kill(processID, SIGTERM)
                }
            }
        }
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: SetupLayout.windowSize.width, height: SetupLayout.windowSize.height),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Set Up Claude Overhead"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(SetupTheme.canvas)
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SetupWindowView(setup: self))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        detectTask?.cancel()
        // A running connect finishes on its own: every write it makes is
        // atomic, and it only marks setup complete after verification.
        let showPreview = closesIntoPreview && flow.isComplete
        closesIntoPreview = false
        onFinish?(showPreview)
    }
}

/// Resumes a continuation exactly once, from whichever of the helper's exit
/// or the timeout comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}
