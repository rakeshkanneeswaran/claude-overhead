import Foundation
import Testing

/// What's New in the app and in the release process. The app target has no
/// tests of its own and the scripts are shell, so these read the sources and
/// pin the rules that keep "the notes shown" and "the version installed" one
/// thing, and that keep a release from shipping without its notes.
@Suite("What's New: app and release wiring")
struct WhatsNewWiringTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) is missing")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    /// `first` appears, and before `second`.
    private static func expect(_ first: String, before second: String, in text: String, _ what: String) throws {
        let a = try #require(text.range(of: first), "\(what): \(first) is missing")
        let b = try #require(text.range(of: second), "\(what): \(second) is missing")
        #expect(a.lowerBound < b.lowerBound, "\(what)")
    }

    // MARK: The app

    @Test("The notes come from the same signed feed entry as the download, for exactly its version")
    func notesComeWithTheDownload() throws {
        let updater = try Self.source("Sources/ChimloApp/ChimloUpdater.swift")
        let offer = try Self.body(of: "private static func offer(for item: SUAppcastItem) -> ReleaseOffer {", in: updater)
        #expect(offer.contains("ReleaseNotesReader.content(feedText: item.itemDescription, expectedVersion: version)"))
        #expect(offer.contains("assetBase: item.fileURL?.deletingLastPathComponent()"))
        // The offer is taken from the item Sparkle is about to act on.
        let found = try Self.body(of: "func showUpdateFound(", in: updater)
        #expect(found.contains("let found = Self.offer(for: appcastItem)"))
        try Self.expect("offerChanged?(found)", before: "install(found.version, replyingTo: reply)", in: found,
                        "the notes are in place before anything installs")
    }

    @Test("Only the version whose notes were shown is installed without being offered")
    func installsOnlyWhatWasShown() throws {
        let updater = try Self.source("Sources/ChimloApp/ChimloUpdater.swift")
        let found = try Self.body(of: "func showUpdateFound(", in: updater)
        // The one install inside showUpdateFound sits behind the guard.
        try Self.expect(
            "|| UpdateInstallGuard.installsWithoutOffering(found: found.version, chosen: chosenVersion) {",
            before: "install(found.version, replyingTo: reply)", in: found, "found updates are installed only when chosen"
        )
        #expect(found.components(separatedBy: "install(").count - 1 == 1)
        #expect(!found.contains("reply(.install)"))
        // Sparkle is told to start an install in one place only; the other
        // reply confirms the relaunch of a download the owner already chose.
        #expect(updater.components(separatedBy: "reply(.install)").count - 1 == 2)
        #expect(try Self.body(of: "private func install(_ version: String, replyingTo reply: (SPUUserUpdateChoice) -> Void) {", in: updater)
            .contains("reply(.install)"))
        #expect(try Self.body(of: "func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {", in: updater)
            .contains("reply(.install)"))

        let install = try Self.body(of: "func installAvailableUpdate(choosing version: String) {", in: updater)
        try Self.expect("guard let offer, offer.version == version else {", before: "install(version, replyingTo: reply)", in: install,
                        "an offer that changed under the window is not installed")

        // The click carries the version whose notes the window was showing,
        // and counts only once they have been up for a moment.
        let model = try Self.source("Sources/ChimloApp/ApplicationModel.swift")
        let button = try Self.body(of: "func installOfferedUpdate(showing version: String) {", in: model)
        #expect(button.contains("guard let offer = updateOffer, offer.version == version, Self.uptime >= whatsNewArmedAt else { return }"))
        #expect(button.contains("updater.installAvailableUpdate(choosing: version)"))
        #expect(model.contains("if offer?.version != updateOffer?.version { armWhatsNew() }"))
        let window = try Self.source("Sources/ChimloApp/WhatsNewWindow.swift")
        #expect(window.contains("update: { model.installOfferedUpdate(showing: content.version) },"))
    }

    @Test("A retry installs only what the owner already chose; a failed check tried again only offers")
    func retryNeedsAChoice() throws {
        let updater = try Self.source("Sources/ChimloApp/ChimloUpdater.swift")
        let retry = try Self.body(of: "func retry() {", in: updater)
        #expect(retry.contains("installs = failure.retryInstallsDirectly && (chosenVersion != nil || installsAnyVersionForTest)"))
        // A plain check forgets an earlier choice before it starts.
        let check = try Self.body(of: "func checkForUpdates() {", in: updater)
        try Self.expect("chosenVersion = nil", before: "beginCheck()", in: check, "a check only ever offers")
        #expect(check.contains("installWhenFound = false"))
        // Installing any version is the update test's alone.
        let test = try Self.body(of: "func installWhateverIsOfferedForTest() {", in: updater)
        try Self.expect(
            #"guard Bundle.main.object(forInfoDictionaryKey: "ChimloUpdateTestMode") as? Bool == true else { return }"#,
            before: "installsAnyVersionForTest = true", in: test, "only an update-test build installs any version"
        )
        #expect(updater.components(separatedBy: "installsAnyVersionForTest = true").count - 1 == 1)
    }

    @Test("Nothing stays armed after a session ends, and a request made during one is not lost")
    func sessionsEndCleanly() throws {
        let updater = try Self.source("Sources/ChimloApp/ChimloUpdater.swift")
        #expect(updater.contains("final class ChimloUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate {"))
        #expect(updater.contains("delegate: self"))
        let ended = try Self.body(of: "didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,", in: updater)
        try Self.expect("if waitsForRunningSession {", before: "installWhenFound = false", in: ended, "a waiting request starts first")
        #expect(ended.contains("shouldPresentErrors = false"))
        #expect(ended.contains("if phase == .checking { publish(nil) }"))
        let begin = try Self.body(of: "private func beginCheck() {", in: updater)
        try Self.expect("guard !updater.sessionInProgress else {", before: "updater.checkForUpdates()", in: begin, "one session at a time")
        #expect(begin.contains("waitsForRunningSession = true"))
    }

    @Test("Checking for updates opens What's New and never starts a download")
    func checkingNeverInstalls() throws {
        let model = try Self.source("Sources/ChimloApp/ApplicationModel.swift")
        let check = try Self.body(of: "func checkForUpdates() {", in: model)
        #expect(check.contains("updater.checkForUpdates()"))
        #expect(!check.contains("install"))
        // The Settings button on an offer opens the walkthrough.
        let settingsAction = try Self.body(of: "func installUpdate() {", in: model)
        #expect(settingsAction.contains("case .available: showWhatsNewForUpdate()"))
        #expect(!settingsAction.contains("installAvailableUpdate"))
        // A check the owner asked for shows the offer; a background one stays in the notch.
        let updater = try Self.source("Sources/ChimloApp/ChimloUpdater.swift")
        let found = try Self.body(of: "func showUpdateFound(", in: updater)
        #expect(found.contains("let ownerAsked = shouldPresentErrors"))
        #expect(found.contains("if ownerAsked { ownerShouldSeeOffer?() }"))
        // Only the What's New window's button installs, and the unattended
        // update test through its own entry.
        let callers = try FileManager.default.contentsOfDirectory(atPath: Self.root.appendingPathComponent("Sources/ChimloApp").path)
            .filter { $0.hasSuffix(".swift") && $0 != "ChimloUpdater.swift" }
            .map { try Self.source("Sources/ChimloApp/\($0)") }
            .joined()
        #expect(callers.components(separatedBy: "installAvailableUpdate(").count - 1 == 1)
        #expect(callers.components(separatedBy: "installWhateverIsOfferedForTest(").count - 1 == 1)
        #expect(callers.contains("if ProcessInfo.processInfo.arguments.contains(\"--update-test-auto-install\") {\n                updater.installWhateverIsOfferedForTest()"))
        #expect(callers.components(separatedBy: "installOfferedUpdate(showing:").count - 1 == 2)
    }

    @Test("The notch's update row opens What's New")
    func notchRowOpensWhatsNew() throws {
        let views = try Self.source("Sources/ChimloApp/IslandViews.swift")
        let action = try Self.body(of: "private func primaryAction() {", in: views)
        #expect(action.contains("model.showWhatsNewForUpdate()"))
        #expect(!action.contains("installUpdate"))
    }

    @Test("Update Now has no key: the window can open while the owner is typing")
    func updateNowTakesAClick() throws {
        let window = try Self.source("Sources/ChimloApp/WhatsNewWindow.swift")
        #expect(window.contains(#"Button("Update Now", action: actions.update)"#))
        // The only keys in the window move between pages.
        #expect(window.components(separatedBy: ".keyboardShortcut(").count - 1 == 2)
        #expect(window.contains(".keyboardShortcut(.leftArrow, modifiers: [])"))
        #expect(window.contains(".keyboardShortcut(.rightArrow, modifiers: [])"))
        #expect(!window.contains(".defaultAction"))
    }

    @Test("The window draws what the notes say: no release's words or pictures live in the views")
    func viewsHoldNoReleaseContent() throws {
        let notes = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.root.appendingPathComponent("ReleaseNotes/1.1.0.json"))
        ) as? [String: Any]
        let cards = try #require(notes?["cards"] as? [[String: Any]])
        let titles = cards.compactMap { $0["title"] as? String }
        #expect(titles.count == cards.count && !titles.isEmpty)
        for file in ["WhatsNewWindow.swift", "WhatsNewVisuals.swift", "CompanionSettings.swift", "SettingsView.swift"] {
            let text = try Self.source("Sources/ChimloApp/\(file)")
            for title in titles { #expect(!text.contains(title), "\(file) holds a card's title") }
            #expect(!text.contains("1.1.0"), "\(file) names a release")
        }
        // A card without a drawable visual gets none: nothing generic stands in.
        let window = try Self.source("Sources/ChimloApp/WhatsNewWindow.swift")
        #expect(window.contains("guard let visual = card.visual, visual.isSupported else { return nil }"))
        let visuals = try Self.source("Sources/ChimloApp/WhatsNewVisuals.swift")
        #expect(visuals.contains("case .unsupported:\n            EmptyView()"))
        // A picture is shown only after its SHA-256 was checked.
        let load = try Self.body(of: "func load(_ image: ReleaseImage, from assets: WhatsNewAssets) async -> NSImage? {", in: visuals)
        try Self.expect("ReleaseImageCheck.accepts(data, for: image)", before: "images[hash] = picture", in: load, "pictures are checked")
    }

    @Test("Bundled notes are shown only for the installed version; a development build says Preview")
    func installedNotes() throws {
        let window = try Self.source("Sources/ChimloApp/WhatsNewWindow.swift")
        let load = try Self.body(of: "static func load(bundle: Bundle = .main) -> InstalledReleaseNotes? {", in: window)
        #expect(load.contains("ReleaseNotesReader.content(data: data, expectedVersion: installed)"))
        #expect(load.contains("bundle.object(forInfoDictionaryKey: \"SUFeedURL\") == nil"))
        #expect(window.contains(#"isPreview ? "Preview What's New in \(notes.version)" : "What's New in \(notes.version)""#))
    }

    // MARK: The release process

    @Test("The signed feed carries the notes, and is checked to carry exactly them")
    func feedCarriesTheNotes() throws {
        let script = try Self.source("Scripts/generate-appcast.sh")
        #expect(script.contains("run overhead-release-notes emit \"$VERSION\""))
        #expect(script.contains("cp \"$WHATS_NEW_DIR/notes.json\" \"$STAGING_ROOT/${ARCHIVE_PATH:t:r}.txt\""))
        #expect(script.contains("--embed-release-notes"))
        try Self.expect(
            #"if [[ "$FEED_VERSION" != "$VERSION" || "$EMBEDDED_NOTES" != "$(<"$WHATS_NEW_DIR/notes.json")" ]]; then"#,
            before: #"cp "$STAGING_ROOT/appcast.xml" "$OUTPUT_PATH""#,
            in: script,
            "the feed is checked before it is handed on"
        )
        // The notes are embedded before the feed is signed, never patched in after.
        try Self.expect("--embed-release-notes", before: #"with_key "$GENERATE_APPCAST""#, in: script, "notes are signed with the feed")
    }

    @Test("No release is built or published without its What's New")
    func releaseRequiresNotes() throws {
        let release = try Self.source("Scripts/public-release.sh")
        try Self.expect(#"./Scripts/check-release-notes.sh --release "$TAG""#, before: #"./Scripts/build-public-dmg.sh "$TAG" "$BUILD_NUMBER""#,
                        in: release, "the notes are checked before anything is built")
        try Self.expect(#"./Scripts/build-public-dmg.sh "$TAG" "$BUILD_NUMBER""#,
                        before: #"./Scripts/check-release-notes.sh --release "$TAG" --app "dist/Claude Overhead.app""#,
                        in: release, "the packaged app is checked once it exists")
        try Self.expect(#"./Scripts/check-release-notes.sh --release "$TAG" --app "dist/Claude Overhead.app""#,
                        before: #"./Scripts/generate-appcast.sh"#, in: release, "the app draws its notes before the feed is signed")
        try Self.expect(#"./Scripts/generate-appcast.sh"#, before: #"./Scripts/publish-github-release.sh "$TAG""#,
                        in: release, "publishing is last")

        let package = try Self.source("Scripts/package-app.sh")
        #expect(package.contains("print -u2 \"There is no ReleaseNotes/$NOTES_VERSION.json. Every release ships its What's New;\""))
        #expect(package.contains("--output \"$RESOURCES_DIR/WhatsNew.json\""))

        let publish = try Self.source("Scripts/publish-github-release.sh")
        try Self.expect(#"|| { print -u2 "$APPCAST does not carry the What's New of $VERSION."; exit 1; }"#,
                        before: "gh release create", in: publish, "nothing is uploaded without the notes")
        #expect(publish.contains(#""${WHATS_NEW_IMAGES[@]}" \"#))
    }

    @Test("There is one way to release: a tagged, pushed, CI-green commit, built here with a build number above the live one")
    func releaseCommand() throws {
        // No workflow publishes on a tag push any more.
        #expect(!FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(".github/workflows/release.yml").path))
        #expect(try Self.source("Makefile").contains(#"./Scripts/public-release.sh "$(TAG)""#))

        let release = try Self.source("Scripts/public-release.sh")
        let order = [
            #"if [[ -n "$(git status --porcelain)" ]]; then"#,
            #"[[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] \"#,
            #"[[ "$REMOTE_COMMIT" == "$HEAD_COMMIT" ]] \"#,
            #"[[ "$INFO_VERSION" == "$VERSION" ]] \"#,
            #"gh run list --repo "$REPOSITORY" --workflow CI --commit "$HEAD_COMMIT""#,
            #"BUILD_NUMBER="${CHIMLO_BUILD_NUMBER:-$(( LIVE_BUILD + 1 ))}""#,
            #"[[ "$BUILD_NUMBER" =~ '^[0-9]+$' ]] && (( BUILD_NUMBER > LIVE_BUILD )) \"#,
            "make check\nmake test",
            #"./Scripts/check-release-notes.sh --release "$TAG""#,
            #"./Scripts/build-public-dmg.sh "$TAG" "$BUILD_NUMBER""#,
            #"if [[ "$DRY_RUN" == "1" ]]; then"#,
            #"./Scripts/publish-github-release.sh "$TAG""#,
        ]
        for (earlier, later) in zip(order, order.dropFirst()) {
            try Self.expect(earlier, before: later, in: release, "the release command's order")
        }
        // A rehearsal stops before the upload.
        let rehearsal = try #require(release.range(of: #"if [[ "$DRY_RUN" == "1" ]]; then"#))
        #expect(release[rehearsal.upperBound...].prefix(400).contains("exit 0"))
        // The build number comes from the live feed, and an older or repeated version is refused.
        #expect(release.contains(#"FEED_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml""#))
        #expect(release.contains(#"fail "$VERSION is older than the live release ($LIVE_VERSION).""#))
        #expect(release.contains(#"|| fail "$VERSION is already the live release.""#))
    }

    @Test("Every push checks the notes: make check, CI and the readiness script")
    func everyPushChecksTheNotes() throws {
        let makefile = try Self.source("Makefile")
        #expect(makefile.contains("check:\n\t./Scripts/swift.sh run overhead-check\n\t./Scripts/swift.sh run overhead-release-notes check\n"))
        let ci = try Self.source(".github/workflows/ci.yml")
        #expect(ci.contains("run: make check"))
        // And the app as built on that push draws every release's notes.
        #expect(ci.contains(#"./Scripts/check-release-notes.sh --render "$(basename "$notes" .json)""#))

        let readiness = try Self.source("Scripts/check-release-notes.sh")
        #expect(readiness.contains(#"tool check --release "$RELEASE""#))
        // The packaged app must carry the published notes and draw every page.
        #expect(readiness.contains(#"/usr/bin/cmp -s "$WORK/notes.json" "$BUNDLED""#))
        #expect(readiness.contains(#""$BINARY" --render-whats-new "$BUNDLED""#))
        #expect(readiness.contains(#"if [[ "$(drawn_pages "$OUTPUT")" != "$(expected_pages "$BUNDLED")" ]]; then"#))

        let releasing = try Self.source("Docs/RELEASING.md")
        #expect(releasing.contains("## What's New"))
        #expect(releasing.contains("ReleaseNotes/<version>.json"))
        #expect(releasing.contains("make whats-new VERSION="))
    }

    @Test("The update test proves the right notes were read, and that the wrong ones are refused")
    func updateTestCoversNotes() throws {
        let script = try Self.source("Scripts/test-local-update.sh")
        #expect(script.contains(#"notes(version: \"$UPDATE_VERSION\", cards: 3)"#))
        #expect(script.contains(#"notes(unavailable: wrongVersion(found: \"$WRONG_NOTES_VERSION\"))"#))
        #expect(try Self.source("Makefile").contains("./Scripts/test-local-update.sh --auto-wrong-notes"))
    }
}
