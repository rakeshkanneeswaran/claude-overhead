import AppKit
import ChimloCore
import Foundation
import Sparkle

/// Drives Sparkle and reports every stage of an update as an
/// `AppUpdatePresentation`. Sparkle owns the hard parts: it reads the signed
/// appcast from the latest GitHub release, downloads the DMG, checks its
/// EdDSA signature against `SUPublicEDKey`, replaces the app only after that
/// succeeds (so a failure leaves the installed app untouched), and relaunches.
@MainActor
final class ChimloUpdater: NSObject, SPUUserDriver {
    var presentationChanged: ((AppUpdatePresentation?) -> Void)?

    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: self,
        delegate: nil
    )
    private var availableUpdateReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedDownloadLength: UInt64?
    private var receivedDownloadLength: UInt64 = 0
    private var started = false
    private var startFailure: AppUpdateFailure?
    /// The owner started this attempt, so its result and errors are shown.
    /// Background checks stay quiet unless they find an update.
    private var shouldPresentErrors = false
    /// A retry after a failed download or install goes straight on to
    /// install the update it finds, instead of offering it again.
    private var installWhenFound = false
    private var phase: AppUpdatePhase?

    func start() {
        guard !started else { return }
        guard Self.isConfigured else {
            startFailure = .notConfigured
            return
        }
        do {
            try updater.start()
            started = true
            startFailure = nil
        } catch {
            startFailure = Self.failure(from: error)
            NSLog("Claude Overhead updater failed to start: %@", error.localizedDescription)
        }
    }

    /// A fresh check the owner asked for.
    func checkForUpdates() {
        if availableUpdateReply != nil {
            // An update is already waiting; checking again would only offer it twice.
            publish(phase)
            return
        }
        guard ensureStarted() else { return }
        guard !updater.sessionInProgress else { return }
        shouldPresentErrors = true
        publish(.checking)
        updater.checkForUpdates()
    }

    /// Installs the offered update, or looks for one and installs it.
    func installAvailableUpdate() {
        if let reply = availableUpdateReply {
            availableUpdateReply = nil
            shouldPresentErrors = true
            publish(.downloading(progress: nil))
            reply(.install)
            return
        }
        installWhenFound = true
        checkForUpdates()
    }

    /// Starts a new attempt after a failure: a download or install that
    /// failed is retried all the way through.
    func retry() {
        var installs = false
        if case let .failed(failure) = phase { installs = failure.retryInstallsDirectly }
        availableUpdateReply = nil
        installWhenFound = installs
        checkForUpdates()
    }

    /// The owner closed an offer in the notch. It stays available in
    /// Settings, and the next scheduled check offers it again.
    func dismissOffer() {
        guard let reply = availableUpdateReply else { return }
        availableUpdateReply = nil
        reply(.dismiss)
    }

    private func ensureStarted() -> Bool {
        if !started { start() }
        guard started else {
            shouldPresentErrors = false
            installWhenFound = false
            publish(.failed(startFailure ?? .notConfigured))
            return false
        }
        return true
    }

    private static var isConfigured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty else { return false }
        return true
    }

    private func publish(_ phase: AppUpdatePhase?) {
        self.phase = phase
        presentationChanged?(phase.map(AppUpdatePresentation.init(phase:)))
    }

    /// Finished states, and an offer the owner closed in the notch, stay
    /// (Settings still lists the update) until something new replaces them.
    private var phaseIsFinished: Bool {
        switch phase {
        case .failed, .upToDate, .updated, .available: true
        default: false
        }
    }

    private static func failure(from error: any Error) -> AppUpdateFailure {
        let chain = errorChain(error)
        return AppUpdateFailure(
            error: chain[0],
            underlying: Array(chain.dropFirst()),
            description: (error as NSError).localizedDescription
        )
    }

    /// The error and up to four beneath it, nearest first.
    private static func errorChain(_ error: any Error) -> [AppUpdateErrorCode] {
        var chain: [AppUpdateErrorCode] = []
        var next: NSError? = error as NSError
        while let current = next, chain.count < 5 {
            chain.append(AppUpdateErrorCode(domain: current.domain, code: current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    // MARK: SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        let automaticUpdateChecks = Bundle.main.object(
            forInfoDictionaryKey: "SUEnableAutomaticChecks"
        ) as? Bool ?? true
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: automaticUpdateChecks,
            automaticUpdateDownloading: false,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        publish(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard !appcastItem.isInformationOnlyUpdate else {
            reply(.dismiss)
            if let infoURL = appcastItem.infoURL {
                NSWorkspace.shared.open(infoURL)
            }
            return
        }
        let version = appcastItem.displayVersionString.isEmpty ? nil : appcastItem.displayVersionString
        if installWhenFound {
            installWhenFound = false
            shouldPresentErrors = true
            publish(.downloading(progress: nil))
            reply(.install)
            return
        }
        availableUpdateReply = reply
        shouldPresentErrors = false
        publish(.available(version: version))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        availableUpdateReply = nil
        installWhenFound = false
        let shouldShowResult = shouldPresentErrors
        shouldPresentErrors = false
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let tooOld = reason?.int32Value == SPUNoUpdateFoundReason.systemIsTooOld.rawValue
        if shouldShowResult {
            publish(tooOld ? .failed(.requiresNewerSystem) : .upToDate)
        } else if !phaseIsFinished {
            publish(nil)
        }
        acknowledgement()
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        availableUpdateReply = nil
        installWhenFound = false
        let shouldShowError = shouldPresentErrors
        shouldPresentErrors = false
        let failure = Self.failure(from: error)
        // Codes only: enough to diagnose, nothing private.
        let codes = Self.errorChain(error).map { "\($0.domain) \($0.code)" }.joined(separator: " <- ")
        NSLog("Claude Overhead update failed (%@): %@", codes, (error as NSError).localizedDescription)
        if shouldShowError {
            publish(.failed(failure))
        } else if !phaseIsFinished {
            // A background check failed. It stays quiet; the next one retries.
            publish(nil)
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedDownloadLength = nil
        receivedDownloadLength = 0
        publish(.downloading(progress: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedDownloadLength = expectedContentLength > 0 ? expectedContentLength : nil
        publishDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedDownloadLength += length
        publishDownloadProgress()
    }

    func showDownloadDidStartExtractingUpdate() {
        publish(.preparing)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if phase != .preparing { publish(.preparing) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        publish(.installing)
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        publish(.restarting)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        shouldPresentErrors = false
        publish(nil)
        acknowledgement()
    }

    /// Sparkle ends every session here, including right after reporting an
    /// error. A finished state stays for the owner to read; anything still
    /// in flight is cleared so nothing is left spinning.
    func dismissUpdateInstallation() {
        availableUpdateReply = nil
        installWhenFound = false
        expectedDownloadLength = nil
        receivedDownloadLength = 0
        shouldPresentErrors = false
        if !phaseIsFinished { publish(nil) }
    }

    private func publishDownloadProgress() {
        let progress = expectedDownloadLength.map { expected in
            Double(receivedDownloadLength) / Double(expected)
        }
        publish(.downloading(progress: progress))
    }
}
