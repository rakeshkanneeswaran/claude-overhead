import ChimloCore
import Foundation
import Testing

@Suite("App update presentation")
struct AppUpdatePresentationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Every lifecycle stage reads clearly: checking, available, downloading, verifying, installing, restarting, updated")
    func lifecycleCopy() {
        let titles: [(AppUpdatePhase, String)] = [
            (.checking, "Checking for updates…"),
            (.available(version: "1.0.4"), "Update to 1.0.4"),
            (.available(version: nil), "Update to latest version"),
            (.downloading(progress: 0.42), "Downloading update 42%"),
            (.downloading(progress: nil), "Downloading update…"),
            (.preparing, "Verifying update…"),
            (.installing, "Installing update…"),
            (.restarting, "Restarting Claude Overhead…"),
            (.updated(version: "1.0.4"), "Updated to 1.0.4"),
            (.upToDate, "Claude Overhead is up to date"),
            (.failed(.offline), "Update failed"),
        ]
        for (phase, title) in titles {
            #expect(AppUpdatePresentation(phase: phase).title == title, "\(phase)")
        }
        let busy: [AppUpdatePhase] = [.checking, .downloading(progress: nil), .preparing, .installing, .restarting]
        for phase in busy {
            let presentation = AppUpdatePresentation(phase: phase)
            #expect(presentation.isBusy && !presentation.isActionable && !presentation.isDismissible, "\(phase)")
        }
    }

    @Test("Download progress is clamped for the pixel meter")
    func progressClamping() {
        #expect(AppUpdatePresentation(phase: .downloading(progress: -0.2)).normalizedProgress == 0)
        #expect(AppUpdatePresentation(phase: .downloading(progress: 0.42)).normalizedProgress == 0.42)
        #expect(AppUpdatePresentation(phase: .downloading(progress: 1.4)).normalizedProgress == 1)
        #expect(AppUpdatePresentation(phase: .downloading(progress: nil)).normalizedProgress == nil)
    }

    @Test("A failure says what went wrong, and Settings says what to do")
    func failureCopy() {
        let failed = AppUpdatePresentation(phase: .failed(.downloadFailed))
        #expect(failed.title == "Update failed")
        #expect(failed.detail == "The download didn't finish")
        #expect(failed.statusText == "Update failed: The download didn't finish. Nothing was installed. Try again.")
        #expect(failed.actionTitle == "Try Again")
        #expect(failed.isActionable && failed.isDismissible)
        #expect(AppUpdatePresentation(phase: .failed(.notConfigured)).actionTitle == "Check Again")
    }

    // MARK: Failure classification

    private let sparkle = AppUpdateFailure.sparkleDomain
    private let url = AppUpdateFailure.urlDomain

    @Test("Sparkle's error codes map to the reason behind them")
    func classifiesSparkleErrors() {
        let cases: [(Int, AppUpdateFailure)] = [
            (1, .notConfigured), (4, .notConfigured), (7, .notConfigured),
            (1000, .releaseUnreadable), (1002, .releaseUnavailable), (1004, .releaseUnavailable),
            (1003, .runningFromDiskImage), (1005, .translocated),
            (2000, .downloadFailed), (2001, .downloadFailed),
            (3000, .damagedDownload), (3001, .signatureMismatch), (3002, .signatureMismatch),
            (4001, .noPermission), (4012, .noPermission),
            (4007, .cancelled), (4008, .cancelled),
            (4000, .installFailed), (4004, .installFailed), (4005, .installFailed), (4009, .installFailed),
        ]
        for (code, expected) in cases {
            #expect(AppUpdateFailure(error: .init(domain: sparkle, code: code)) == expected, "\(code)")
        }
        #expect(AppUpdateFailure(error: .init(domain: sparkle, code: 5000), description: "Odd") == .unknown("Odd"))
    }

    @Test("A refused signature or damaged archive underneath an install error is named as such")
    func decisiveUnderlyingErrors() {
        let install = AppUpdateErrorCode(domain: sparkle, code: 4005)
        #expect(AppUpdateFailure(error: install, underlying: [.init(domain: sparkle, code: 3001)]) == .signatureMismatch)
        #expect(AppUpdateFailure(error: install, underlying: [.init(domain: sparkle, code: 3002)]) == .signatureMismatch)
        #expect(AppUpdateFailure(error: install, underlying: [.init(domain: sparkle, code: 3000)]) == .damagedDownload)
        #expect(AppUpdateFailure(error: install) == .installFailed)
    }

    @Test("A network failure anywhere underneath means GitHub could not be reached")
    func classifiesNetworkFailures() {
        let offline = AppUpdateErrorCode(domain: url, code: NSURLErrorNotConnectedToInternet)
        let timedOut = AppUpdateErrorCode(domain: url, code: NSURLErrorTimedOut)
        #expect(AppUpdateFailure(error: .init(domain: sparkle, code: 1002), underlying: [offline]) == .offline)
        #expect(AppUpdateFailure(error: .init(domain: sparkle, code: 2001), underlying: [timedOut]) == .offline)
        #expect(AppUpdateFailure(error: offline) == .offline)
        // A URL error that is not about reachability is GitHub failing to serve the feed.
        #expect(AppUpdateFailure(error: .init(domain: url, code: NSURLErrorBadServerResponse)) == .releaseUnavailable)
        #expect(AppUpdateFailure(error: .init(domain: "Other", code: 1), description: "Boom") == .unknown("Boom"))
    }

    @Test("Every failure has a reason and a way forward")
    func everyFailureExplainsItself() {
        let all: [AppUpdateFailure] = [
            .notConfigured, .offline, .releaseUnavailable, .releaseUnreadable, .downloadFailed,
            .damagedDownload, .signatureMismatch, .noPermission, .installFailed, .runningFromDiskImage,
            .translocated, .cancelled, .requiresNewerSystem, .unknown(""),
        ]
        for failure in all {
            #expect(!failure.summary.isEmpty && !failure.recovery.isEmpty, "\(failure)")
        }
        #expect(AppUpdateFailure.unknown("").summary == "Something went wrong")
        // Failures after the owner chose to install say the current version is unchanged.
        for failure in [AppUpdateFailure.installFailed, .noPermission] {
            #expect(failure.recovery.contains("unchanged"), "\(failure)")
        }
        #expect(AppUpdateFailure.notConfigured.suggestsInstallCommand)
        #expect(!AppUpdateFailure.offline.suggestsInstallCommand)
    }

    // MARK: Retries

    @Test("A retry starts a fresh attempt, installing directly when the install had already begun")
    func retries() {
        for failure in [AppUpdateFailure.downloadFailed, .damagedDownload, .signatureMismatch, .installFailed, .noPermission, .cancelled] {
            #expect(failure.isRetryable && failure.retryInstallsDirectly, "\(failure)")
        }
        for failure in [AppUpdateFailure.offline, .releaseUnavailable, .releaseUnreadable] {
            #expect(failure.isRetryable && !failure.retryInstallsDirectly, "\(failure)")
        }
        // Trying again cannot fix these, so the notch offers no Retry.
        for failure in [AppUpdateFailure.notConfigured, .requiresNewerSystem, .runningFromDiskImage, .translocated] {
            #expect(!failure.isRetryable, "\(failure)")
        }
    }

    // MARK: The notch row

    @Test("A failure leaves the notch when dismissed, and on its own after a minute")
    func failureNeverSticks() {
        var notice = AppUpdateNotice()
        notice.show(AppUpdatePresentation(phase: .failed(.offline)), at: now)
        #expect(notice.isVisible(at: now))
        #expect(notice.isVisible(at: now.addingTimeInterval(59)))
        #expect(!notice.isVisible(at: now.addingTimeInterval(60)))
        #expect(notice.expiresAt == now.addingTimeInterval(60))

        notice.dismiss()
        #expect(!notice.isVisible(at: now))
        // Settings still has the reason.
        #expect(notice.presentation?.failure == .offline)
    }

    @Test("A new attempt brings a dismissed row back; progress within a stage does not")
    func retryAfterDismissal() {
        var notice = AppUpdateNotice()
        notice.show(AppUpdatePresentation(phase: .failed(.offline)), at: now)
        notice.dismiss()
        notice.show(AppUpdatePresentation(phase: .checking), at: now.addingTimeInterval(5))
        #expect(notice.isVisible(at: now.addingTimeInterval(5)))
        #expect(notice.expiresAt == nil, "busy stages never expire mid-attempt")

        notice.show(AppUpdatePresentation(phase: .downloading(progress: 0.1)), at: now.addingTimeInterval(6))
        let started = notice.shownAt
        notice.show(AppUpdatePresentation(phase: .downloading(progress: 0.8)), at: now.addingTimeInterval(9))
        #expect(notice.shownAt == started)
        // Busy rows cannot be dismissed: the attempt has to finish.
        notice.dismiss()
        #expect(notice.isVisible(at: now.addingTimeInterval(9)))
    }

    @Test("An offer stays until installed or dismissed; finished states expire")
    func lifetimes() {
        #expect(AppUpdatePresentation(phase: .available(version: "1.0.4")).notchLifetime == nil)
        #expect(AppUpdatePresentation(phase: .updated(version: "1.0.4")).notchLifetime == 8)
        #expect(AppUpdatePresentation(phase: .failed(.installFailed)).notchLifetime == 60)

        var offer = AppUpdateNotice()
        offer.show(AppUpdatePresentation(phase: .available(version: "1.0.4")), at: now)
        #expect(offer.isVisible(at: now.addingTimeInterval(86_400)))
        offer.dismiss()
        #expect(!offer.isVisible(at: now))
        // The same offer again (a scheduled check) stays dismissed until the next launch.
        offer.show(AppUpdatePresentation(phase: .available(version: "1.0.4")), at: now.addingTimeInterval(3600))
        #expect(!offer.isVisible(at: now.addingTimeInterval(3600)))

        var updated = AppUpdateNotice()
        updated.show(AppUpdatePresentation(phase: .updated(version: "1.0.4")), at: now)
        #expect(updated.isVisible(at: now.addingTimeInterval(7)))
        #expect(!updated.isVisible(at: now.addingTimeInterval(8)))
    }

    @Test("Clearing the state clears the row")
    func clearing() {
        var notice = AppUpdateNotice()
        notice.show(AppUpdatePresentation(phase: .installing), at: now)
        notice.show(nil, at: now)
        #expect(!notice.isVisible(at: now))
        #expect(notice.expiresAt == nil)
    }

    @Test("Up to date answers in Settings; Claude's requests outrank update rows")
    func priority() {
        var upToDate = AppUpdateNotice()
        upToDate.show(AppUpdatePresentation(phase: .upToDate), at: now)
        #expect(!AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            notice: upToDate, now: now, hasOwnerInteraction: false
        ))

        var failed = AppUpdateNotice()
        failed.show(AppUpdatePresentation(phase: .failed(.downloadFailed)), at: now)
        #expect(AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            notice: failed, now: now, hasOwnerInteraction: false
        ))
        #expect(!AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            notice: failed, now: now, hasOwnerInteraction: true
        ))
        #expect(!AppUpdatePresentationPolicy.shouldTakeIdlePanel(
            notice: failed, now: now.addingTimeInterval(61), hasOwnerInteraction: false
        ))
    }

    // MARK: Versions

    @Test("Versions compare number by number")
    func versions() throws {
        let v = { (string: String) in try #require(AppVersion(string)) }
        #expect(try v("1.0.10") > v("1.0.9"))
        #expect(try v("1.1") > v("1.0.9"))
        #expect(try v("1.0") == v("1.0.0"))
        #expect(try v("2.0.0") > v("1.99.99"))
        #expect(AppVersion("1.0.x") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("1..0") == nil)
    }

    @Test("Updated to … shows once, only after moving to a newer version")
    func updatedNotice() {
        #expect(AppUpdateLaunch.updatedVersion(previous: "1.0.3", current: "1.0.4") == "1.0.4")
        #expect(AppUpdateLaunch.updatedVersion(previous: "1.0.4", current: "1.0.4") == nil)
        #expect(AppUpdateLaunch.updatedVersion(previous: nil, current: "1.0.4") == nil, "first launch ever")
        #expect(AppUpdateLaunch.updatedVersion(previous: "1.0.5", current: "1.0.4") == nil, "downgrade")
        #expect(AppUpdateLaunch.updatedVersion(previous: "garbage", current: "1.0.4") == nil)
    }
}
