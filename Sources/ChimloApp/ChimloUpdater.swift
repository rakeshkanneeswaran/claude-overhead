import AppKit
import ChimloCore
import Foundation
import Sparkle

/// Drives Sparkle and reports every stage of an update as an
/// `AppUpdatePresentation`. Sparkle owns the hard parts: it reads the signed
/// appcast from the latest GitHub release, downloads the DMG, checks its
/// EdDSA signature against `SUPublicEDKey`, replaces the app only after that
/// succeeds (so a failure leaves the installed app untouched), and relaunches.
///
/// The same feed entry carries the release's What's New, so the notes shown
/// and the download installed are always one release (see `ReleaseOffer`).
@MainActor
final class ChimloUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    var presentationChanged: ((AppUpdatePresentation?) -> Void)?
    /// The update on offer with the notes that came with it, or nil.
    var offerChanged: ((ReleaseOffer?) -> Void)?
    /// A check the owner asked for found an update: time to show its notes.
    var ownerShouldSeeOffer: (() -> Void)?

    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: self,
        delegate: self
    )
    private var availableUpdateReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedDownloadLength: UInt64?
    private var receivedDownloadLength: UInt64 = 0
    private var started = false
    private var startFailure: AppUpdateFailure?
    /// The owner started this attempt, so its result and errors are shown.
    /// Background checks stay quiet unless they find an update.
    private var shouldPresentErrors = false
    /// The check now starting may install what it finds without offering it
    /// again, but only the version the owner already chose (`chosenVersion`).
    private var installWhenFound = false
    private var phase: AppUpdatePhase?
    private var offer: ReleaseOffer?
    /// The version the owner chose to install, with "Update Now" under its
    /// notes. No other version is ever installed without being offered.
    private var chosenVersion: String?
    /// The unattended update test installs whatever the feed offers.
    /// Update-test builds only.
    private var installsAnyVersionForTest = false
    /// The owner asked for something while a scheduled check was still
    /// running. Sparkle runs one session at a time, so theirs starts when
    /// that one ends.
    private var waitsForRunningSession = false

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

    /// A fresh check the owner asked for. It only ever offers: whatever was
    /// chosen in an earlier attempt is forgotten, so nothing it finds is
    /// installed before the owner has seen it.
    func checkForUpdates() {
        if availableUpdateReply != nil {
            // An update is already waiting; checking again would only offer it twice.
            publish(phase)
            ownerShouldSeeOffer?()
            return
        }
        installWhenFound = false
        chosenVersion = nil
        beginCheck()
    }

    /// Starts a check on the owner's behalf, with `installWhenFound` and
    /// `chosenVersion` as the caller left them.
    private func beginCheck() {
        guard ensureStarted() else { return }
        shouldPresentErrors = true
        guard !updater.sessionInProgress else {
            // A scheduled check is running, and it may end without telling
            // the driver anything. The owner's request waits for it: if it
            // finds an update, that is theirs; if not, their own check starts
            // when it ends (see `updater(_:didFinishUpdateCycleFor:error:)`).
            waitsForRunningSession = true
            if phase == nil { publish(.checking) }
            return
        }
        waitsForRunningSession = false
        publish(.checking)
        updater.checkForUpdates()
    }

    /// "Update Now" under the notes of `version`: installs that release and
    /// no other. If something else is on offer, or turns up when the feed is
    /// read again, it is offered first, with its own notes.
    func installAvailableUpdate(choosing version: String) {
        if let reply = availableUpdateReply {
            guard let offer, offer.version == version else {
                // The offer changed under the window. Show what is on offer
                // now instead of installing something the owner did not read.
                offerChanged?(offer)
                publish(phase)
                return
            }
            install(version, replyingTo: reply)
            return
        }
        // The offer was closed in the notch: read the feed again, and
        // install only if it still offers this version.
        chosenVersion = version
        installWhenFound = true
        beginCheck()
    }

    /// The unattended update test: installs whatever the feed offers, with
    /// no window and no click. Does nothing outside an update-test build.
    func installWhateverIsOfferedForTest() {
        guard Bundle.main.object(forInfoDictionaryKey: "ChimloUpdateTestMode") as? Bool == true else { return }
        installsAnyVersionForTest = true
        if let reply = availableUpdateReply, let offer {
            install(offer.version, replyingTo: reply)
            return
        }
        installWhenFound = true
        beginCheck()
    }

    private func install(_ version: String, replyingTo reply: (SPUUserUpdateChoice) -> Void) {
        availableUpdateReply = nil
        chosenVersion = version
        shouldPresentErrors = true
        publish(.downloading(progress: nil))
        reply(.install)
    }

    /// Starts a new attempt after a failure. Only a failure that came after
    /// the owner chose a version (the download, the verification, the
    /// install) is retried all the way through, and only for that version.
    /// A check that failed before any choice is simply made again, and what
    /// it finds is offered.
    func retry() {
        var installs = false
        if case let .failed(failure) = phase {
            installs = failure.retryInstallsDirectly && (chosenVersion != nil || installsAnyVersionForTest)
        }
        availableUpdateReply = nil
        installWhenFound = installs
        if !installs { chosenVersion = nil }
        beginCheck()
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
        let found = Self.offer(for: appcastItem)
        offer = found
        offerChanged?(found)
        waitsForRunningSession = false
        if installWhenFound {
            installWhenFound = false
            if installsAnyVersionForTest
                || UpdateInstallGuard.installsWithoutOffering(found: found.version, chosen: chosenVersion) {
                install(found.version, replyingTo: reply)
                return
            }
            // Not the release the owner chose (a newer one appeared since).
            // It is offered with its own notes, not installed under the old ones.
            chosenVersion = nil
        }
        let ownerAsked = shouldPresentErrors
        availableUpdateReply = reply
        shouldPresentErrors = false
        publish(.available(version: version))
        if ownerAsked { ownerShouldSeeOffer?() }
    }

    /// The feed entry as an offer: its version, and the notes embedded in
    /// the same signed entry as the download.
    private static func offer(for item: SUAppcastItem) -> ReleaseOffer {
        let version = item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return ReleaseOffer(
            version: version,
            installedVersion: installed,
            content: ReleaseNotesReader.content(feedText: item.itemDescription, expectedVersion: version),
            assetBase: item.fileURL?.deletingLastPathComponent()
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        availableUpdateReply = nil
        installWhenFound = false
        waitsForRunningSession = false
        chosenVersion = nil
        if offer != nil {
            offer = nil
            offerChanged?(nil)
        }
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
        waitsForRunningSession = false
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

    // MARK: SPUUpdaterDelegate

    /// Every Sparkle session ends here, including a scheduled check that
    /// found nothing and so told the driver nothing.
    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if waitsForRunningSession {
            // The owner asked while that session was running, and it ended
            // without an answer for them. Their own check starts now.
            beginCheck()
            return
        }
        // Nothing stays armed for a session that is over: the next scheduled
        // check must only ever offer, quietly.
        installWhenFound = false
        shouldPresentErrors = false
        if phase == .checking { publish(nil) }
    }

    private func publishDownloadProgress() {
        let progress = expectedDownloadLength.map { expected in
            Double(receivedDownloadLength) / Double(expected)
        }
        publish(.downloading(progress: progress))
    }
}
