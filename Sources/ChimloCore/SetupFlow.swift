import Foundation

/// One real step of connecting Claude Code. Each stage names work the app
/// actually does, in order; none of them is decoration.
public enum SetupStage: Int, CaseIterable, Comparable, Sendable {
    case checkingClaudeCode
    case preparingHelper
    case updatingSettings
    case verifying

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .checkingClaudeCode: "Checking Claude Code"
        case .preparingHelper: "Preparing the Overhead helper"
        case .updatingSettings: "Updating Claude Code's settings"
        case .verifying: "Verifying the connection"
        }
    }

    var next: SetupStage? { SetupStage(rawValue: rawValue + 1) }
}

public struct SetupFailure: Equatable, Sendable {
    public let stage: SetupStage
    /// What went wrong, in words a person can act on.
    public let message: String
    /// The technical cause, shown behind a disclosure. Never session content.
    public let details: String

    public init(stage: SetupStage, message: String, details: String) {
        self.stage = stage
        self.message = message
        self.details = details
    }
}

/// The first-launch setup journey as a value: which screen shows and the rules
/// for moving between them. It runs no side effects. `SetupCoordinator` does
/// the real work and reports each result here, so these rules stay testable.
public struct SetupFlow: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case welcome
        case findClaudeCode
        case explain
        case connecting(SetupStage)
        case failed(SetupFailure)
        case connected
    }

    public enum Detection: Equatable, Sendable {
        case checking
        case found(ClaudeCodeInstallation)
        case notFound
        case failed(String)
    }

    public private(set) var step: Step
    public private(set) var detection: Detection = .checking
    /// Hooks are already in place, so setup can verify instead of install.
    public private(set) var integrationInstalled: Bool
    /// Hooks exist but no longer match what Overhead expects.
    public private(set) var integrationNeedsRepair: Bool
    /// What each finished stage actually did, for the progress list.
    public private(set) var stageResults: [SetupStage: String] = [:]

    init(step: Step, integrationInstalled: Bool, integrationNeedsRepair: Bool) {
        self.step = step
        self.integrationInstalled = integrationInstalled
        self.integrationNeedsRepair = integrationNeedsRepair
    }

    /// The flow to show at launch, or nil when setup already finished. A
    /// finished setup is never repeated; an unfinished one starts again, and
    /// offers to verify instead of install when hooks are already there.
    public static func atLaunch(
        hasCompletedSetup: Bool,
        integrationInstalled: Bool,
        integrationNeedsRepair: Bool
    ) -> SetupFlow? {
        guard !hasCompletedSetup else { return nil }
        return SetupFlow(
            step: .welcome,
            integrationInstalled: integrationInstalled,
            integrationNeedsRepair: integrationNeedsRepair
        )
    }

    /// For reconnecting later, from the notch or Settings: skip the welcome
    /// and go straight to what connecting changes.
    public static func reconnecting(integrationNeedsRepair: Bool) -> SetupFlow {
        SetupFlow(step: .explain, integrationInstalled: false, integrationNeedsRepair: integrationNeedsRepair)
    }

    /// Setup counts as done only once the connection was verified.
    public var isComplete: Bool { step == .connected }

    public var isConnecting: Bool {
        if case .connecting = step { return true }
        return false
    }

    public var canGoBack: Bool {
        switch step {
        case .findClaudeCode, .explain, .failed: true
        case .welcome, .connecting, .connected: false
        }
    }

    public mutating func getStarted() {
        guard step == .welcome else { return }
        step = .findClaudeCode
    }

    public mutating func detectionStarted() {
        detection = .checking
    }

    public mutating func detectionFinished(_ result: Detection) {
        detection = result
    }

    public mutating func continueToExplain() {
        guard step == .findClaudeCode, case .found = detection else { return }
        step = .explain
    }

    /// Starts connecting, from the explanation, a failed attempt, or the
    /// welcome's "already connected" shortcut. Returns false while a
    /// connection is already running, so a double click never starts two.
    @discardableResult
    public mutating func beginConnecting() -> Bool {
        switch step {
        case .explain, .failed:
            break
        case .welcome where integrationInstalled:
            break
        case .welcome, .findClaudeCode, .connecting, .connected:
            return false
        }
        stageResults = [:]
        step = .connecting(.checkingClaudeCode)
        return true
    }

    /// Records that the running stage finished, and moves to the next one.
    /// The last stage does not finish here: only `connectionVerified` may.
    public mutating func stageFinished(_ stage: SetupStage, result: String) {
        guard case let .connecting(current) = step, current == stage,
              let next = stage.next else { return }
        stageResults[stage] = result
        step = .connecting(next)
    }

    public mutating func connectionVerified(result: String) {
        guard step == .connecting(.verifying) else { return }
        stageResults[.verifying] = result
        integrationInstalled = true
        integrationNeedsRepair = false
        step = .connected
    }

    public mutating func connectionFailed(_ failure: SetupFailure) {
        guard isConnecting else { return }
        step = .failed(failure)
    }

    public mutating func back() {
        switch step {
        case .findClaudeCode: step = .welcome
        case .explain: step = .findClaudeCode
        case .failed: step = .explain
        case .welcome, .connecting, .connected: break
        }
    }
}
