import ChimloCore
import Foundation
import Testing

@Suite("Hide outside the notch")
struct NotchVisibilityTests {
    private func display(width: CGFloat = 1512, housing: Bool = true, menuBar: CGFloat = 32) -> IslandDisplayMetrics {
        IslandDisplayMetrics(
            screenWidth: width,
            screenHeight: 982,
            visibleTop: 982 - menuBar,
            safeTopInset: housing ? 32 : 0,
            cameraHousingLeftEdge: housing ? 664 : nil,
            cameraHousingRightEdge: housing ? 848 : nil,
            menuBarHeight: menuBar
        )
    }

    @Test("Hidden and closed, the notch is concealed")
    func concealsWhenClosed() {
        #expect(NotchVisibilityPolicy.conceals(isHidden: true, isClosed: true, hasPendingOwnerRequest: false))
        // Opened by a click, it shows in full.
        #expect(!NotchVisibilityPolicy.conceals(isHidden: true, isClosed: false, hasPendingOwnerRequest: false))
        // Not hidden: nothing changes.
        #expect(!NotchVisibilityPolicy.conceals(isHidden: false, isClosed: true, hasPendingOwnerRequest: false))
    }

    @Test("A request Claude is waiting on is never hidden")
    func requestsShow() {
        #expect(!NotchVisibilityPolicy.conceals(isHidden: true, isClosed: true, hasPendingOwnerRequest: true))
        // And it opens the notch exactly as Lock Mode decides without hiding.
        #expect(NotchLockPolicy.opens(.ownerRequest, isLocked: false, isHidden: true))
        #expect(!NotchLockPolicy.opens(.ownerRequest, isLocked: true, isHidden: true))
    }

    @Test("Hidden, the notch opens only when the owner opens it")
    func onlyAClickOpens() {
        for trigger in [NotchLockPolicy.Trigger.hover, .sessionFailure, .updateNotice] {
            #expect(!NotchLockPolicy.opens(trigger, isLocked: false, isHidden: true), "\(trigger)")
        }
        #expect(NotchLockPolicy.opens(.ownerAction, isLocked: false, isHidden: true))
        #expect(NotchLockPolicy.opens(.ownerAction, isLocked: true, isHidden: true))
    }

    @Test("Shown, every trigger behaves as before")
    func shownUnchanged() {
        for trigger in NotchLockPolicy.Trigger.allCases {
            #expect(
                NotchLockPolicy.opens(trigger, isLocked: false, isHidden: false)
                    == NotchLockPolicy.opens(trigger, isLocked: false),
                "\(trigger)"
            )
            #expect(
                NotchLockPolicy.opens(trigger, isLocked: true, isHidden: false)
                    == NotchLockPolicy.opens(trigger, isLocked: true),
                "\(trigger)"
            )
        }
    }

    @Test("Concealed, the notch is exactly the camera housing, whatever the layout")
    func concealedSizeIsTheHousing() {
        for scale in [0.8, 1.0, 1.5, 1.8] {
            let layout = IslandLayout.make(for: display(), wingWidthScale: scale)
            #expect(layout.concealedWidth == 184)
            #expect(layout.concealedHeight == 32)
            #expect(layout.concealedWidth < layout.compactWidth)
        }
    }

    @Test("Without a camera housing, the target sits in the menu bar's height")
    func noHousing() {
        let layout = IslandLayout.make(for: display(housing: false, menuBar: 24))
        #expect(layout.concealedWidth == 198)
        #expect(layout.concealedHeight == 24)
        // A hidden menu bar (fullscreen) still leaves something to click.
        #expect(IslandLayout.make(for: display(housing: false, menuBar: 0)).concealedHeight == 22)
    }

    @Test("Hidden is off by default, survives a restart, and is separate from Lock Mode and the layout")
    func persistence() throws {
        let defaults = OverheadSettings()
        #expect(!defaults.notchHidden)
        var settings = OverheadSettings()
        settings.notchHidden = true
        let decoded = try JSONDecoder().decode(OverheadSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.notchHidden)
        #expect(!decoded.notchLocked)
        #expect(decoded.layout == defaults.layout)
        // Settings saved before this existed read as shown.
        let older = try JSONDecoder().decode(OverheadSettings.self, from: Data(#"{"version":1,"notchLocked":true}"#.utf8))
        #expect(!older.notchHidden)
        #expect(older.notchLocked)
    }

    @Test("Search finds it")
    func searchable() {
        for query in ["hide", "fullscreen", "video", "eye"] {
            #expect(SettingsCatalog.search(query).contains { $0.id == "notchHidden" }, "\(query)")
        }
    }
}

/// The app half lives in the app target, which has no tests of its own, so
/// this reads its source (as the other wiring suites do).
@Suite("Hide outside the notch: app wiring")
struct NotchVisibilityWiringTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    private static func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    @Test("Every place the notch opens by itself knows whether it is hidden")
    func everyOpeningPathReadsHidden() throws {
        let model = try Self.source("ApplicationModel.swift")
        let calls = model.components(separatedBy: "NotchLockPolicy.opens(").dropFirst()
        #expect(calls.count >= 7)
        for call in calls {
            let arguments = String(call.prefix(while: { $0 != "{" && $0 != "\n" }))
            #expect(arguments.contains("isHidden: isNotchHidden"), "opens(\(arguments)")
        }
    }

    @Test("The concealed notch keeps its click target and draws no glow")
    func concealedNotch() throws {
        let views = try Self.source("IslandViews.swift")
        let model = try Self.source("ApplicationModel.swift")
        // The closed notch's button stays; only its content fades.
        #expect(views.contains("Button(action: model.openPanel)"))
        #expect(views.contains(".opacity(model.isNotchConcealed ? 0 : 1)"))
        #expect(model.contains("case .compact where isNotchConcealed:"))
        #expect(model.contains("guard !isNotchConcealed else { return }"))
        // The eye button is in the open notch, and its state is saved.
        #expect(views.contains("NotchVisibilityButton(model: model)"))
        let services = try Self.source("OverheadServices.swift")
        #expect(services.contains("settings.settings.notchHidden = hidden"))
        #expect(model.contains("if isNotchHidden != settings.notchHidden { isNotchHidden = settings.notchHidden }"))
    }
}
