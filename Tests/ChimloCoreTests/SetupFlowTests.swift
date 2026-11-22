import Testing
@testable import ChimloCore

@Suite("First-launch setup flow")
struct SetupFlowTests {
    private let installation = ClaudeCodeInstallation(source: .commandLine, path: "/opt/homebrew/bin/claude")

    private func connectThroughAllStages(_ flow: inout SetupFlow) {
        for stage in SetupStage.allCases.dropLast() {
            flow.stageFinished(stage, result: "done")
        }
    }

    @Test("A first launch opens setup at the welcome; a finished setup never repeats")
    func launchDecision() throws {
        let first = try #require(SetupFlow.atLaunch(
            hasCompletedSetup: false,
            integrationInstalled: false,
            integrationNeedsRepair: false
        ))
        #expect(first.step == .welcome)
        #expect(!first.isComplete)

        #expect(SetupFlow.atLaunch(hasCompletedSetup: true, integrationInstalled: false, integrationNeedsRepair: false) == nil)
        #expect(SetupFlow.atLaunch(hasCompletedSetup: true, integrationInstalled: true, integrationNeedsRepair: false) == nil)
    }

    @Test("An unfinished setup resumes from the start after a relaunch")
    func relaunchResumesSafely() throws {
        var flow = try #require(SetupFlow.atLaunch(hasCompletedSetup: false, integrationInstalled: false, integrationNeedsRepair: false))
        flow.getStarted()
        flow.detectionFinished(.found(installation))
        flow.continueToExplain()
        // The app quits here. Nothing was persisted, so the next launch starts over.
        let relaunched = try #require(SetupFlow.atLaunch(hasCompletedSetup: false, integrationInstalled: false, integrationNeedsRepair: false))
        #expect(relaunched.step == .welcome)
    }

    @Test("Only a verified connection completes setup")
    func verificationCompletes() {
        var flow = SetupFlow.reconnecting(integrationNeedsRepair: false)
        let started1 = flow.beginConnecting()
        #expect(started1)
        connectThroughAllStages(&flow)
        #expect(flow.step == .connecting(.verifying))
        #expect(!flow.isComplete)

        flow.connectionVerified(result: "Helper reached the app")
        #expect(flow.isComplete)
        #expect(flow.integrationInstalled)
        #expect(flow.stageResults.count == SetupStage.allCases.count)
    }

    @Test("A failed verification never completes setup, and retry starts over")
    func failureDoesNotComplete() {
        var flow = SetupFlow.reconnecting(integrationNeedsRepair: false)
        flow.beginConnecting()
        connectThroughAllStages(&flow)
        let failure = SetupFailure(stage: .verifying, message: "No answer", details: "timeout")
        flow.connectionFailed(failure)
        #expect(flow.step == .failed(failure))
        #expect(!flow.isComplete)

        // A late "verified" from the failed attempt must not sneak through.
        flow.connectionVerified(result: "late")
        #expect(!flow.isComplete)

        let started2 = flow.beginConnecting()
        #expect(started2)
        #expect(flow.step == .connecting(.checkingClaudeCode))
        #expect(flow.stageResults.isEmpty)
    }

    @Test("A second Connect while connecting is refused")
    func duplicateConnectIsRefused() {
        var flow = SetupFlow.reconnecting(integrationNeedsRepair: false)
        let started3 = flow.beginConnecting()
        #expect(started3)
        let started4 = flow.beginConnecting()
        #expect(!started4)
        flow.stageFinished(.checkingClaudeCode, result: "found")
        let started5 = flow.beginConnecting()
        #expect(!started5)
        #expect(flow.step == .connecting(.preparingHelper))
    }

    @Test("Stages only advance in order")
    func stagesAdvanceInOrder() {
        var flow = SetupFlow.reconnecting(integrationNeedsRepair: false)
        flow.beginConnecting()
        flow.stageFinished(.updatingSettings, result: "out of order")
        #expect(flow.step == .connecting(.checkingClaudeCode))
        flow.stageFinished(.verifying, result: "the last stage only finishes when verified")
        #expect(flow.step == .connecting(.checkingClaudeCode))
    }

    @Test("Continue needs a detected Claude Code, and Back retraces the screens")
    func navigation() throws {
        var flow = try #require(SetupFlow.atLaunch(hasCompletedSetup: false, integrationInstalled: false, integrationNeedsRepair: false))
        #expect(!flow.canGoBack)
        flow.getStarted()
        #expect(flow.step == .findClaudeCode)

        flow.detectionFinished(.notFound)
        flow.continueToExplain()
        #expect(flow.step == .findClaudeCode)

        flow.detectionFinished(.found(installation))
        flow.continueToExplain()
        #expect(flow.step == .explain)

        flow.back()
        #expect(flow.step == .findClaudeCode)
        flow.back()
        #expect(flow.step == .welcome)
    }

    @Test("The welcome offers to verify only when hooks already exist")
    func alreadyConnectedShortcut() throws {
        var fresh = try #require(SetupFlow.atLaunch(hasCompletedSetup: false, integrationInstalled: false, integrationNeedsRepair: false))
        let started6 = fresh.beginConnecting()
        #expect(!started6)

        var connected = try #require(SetupFlow.atLaunch(hasCompletedSetup: false, integrationInstalled: true, integrationNeedsRepair: false))
        let started7 = connected.beginConnecting()
        #expect(started7)
        #expect(connected.step == .connecting(.checkingClaudeCode))
    }

    @Test("Reconnecting after a disconnect skips the welcome")
    func reconnectAfterDisconnect() {
        let flow = SetupFlow.reconnecting(integrationNeedsRepair: true)
        #expect(flow.step == .explain)
        #expect(flow.integrationNeedsRepair)
        #expect(flow.canGoBack)
    }
}

@Suite("Claude Code detection")
struct ClaudeCodeInstallationTests {
    private let home = "/Users/me"

    private func detect(
        executables: Set<String> = [],
        directories: Set<String> = [],
        listings: [String: [String]] = [:],
        path: String? = nil
    ) -> ClaudeCodeInstallation? {
        ClaudeCodeLocator.detect(
            home: home,
            path: path,
            isExecutable: { executables.contains($0) },
            directoryExists: { directories.contains($0) },
            contentsOfDirectory: { listings[$0] ?? [] }
        )
    }

    @Test("The command line wins, found on the PATH or in a standard install place")
    func commandLine() {
        #expect(detect(executables: ["/opt/homebrew/bin/claude"])
            == ClaudeCodeInstallation(source: .commandLine, path: "/opt/homebrew/bin/claude"))
        #expect(detect(executables: ["/Users/me/.local/bin/claude"])?.source == .commandLine)
        #expect(detect(executables: ["/custom/bin/claude"], path: "/usr/bin:/custom/bin")?.path == "/custom/bin/claude")
    }

    @Test("Without a command line, the newest editor extension counts")
    func editorExtension() {
        let root = "/Users/me/.vscode/extensions"
        let found = detect(
            directories: [root, "/Users/me/.claude"],
            listings: [root: ["ms-python.python-1", "anthropic.claude-code-2.1.300", "anthropic.claude-code-2.1.325"]]
        )
        #expect(found == ClaudeCodeInstallation(source: .editorExtension, path: "\(root)/anthropic.claude-code-2.1.325"))
    }

    @Test("A settings folder alone counts, because every Claude Code surface uses it")
    func settingsFolder() {
        #expect(detect(directories: ["/Users/me/.claude"])?.source == .settingsFolder)
    }

    @Test("Nothing found means not installed")
    func notInstalled() {
        #expect(detect() == nil)
        #expect(detect(directories: ["/Users/me/.vscode/extensions"], listings: ["/Users/me/.vscode/extensions": ["ms-python.python-1"]]) == nil)
    }

    @Test("Candidates have no duplicates and keep the PATH first")
    func candidatesAreOrdered() {
        let candidates = ClaudeCodeLocator.executableCandidates(home: home, path: "/opt/homebrew/bin:/usr/bin")
        #expect(candidates.first == "/opt/homebrew/bin/claude")
        #expect(candidates.count == Set(candidates).count)
    }
}
