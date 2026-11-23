import Foundation
import Testing

/// The app-target half of the 1.0.9 audit. The app has no tests of its own,
/// so these read its source and pin the rules that were found broken.
@Suite("Audit 1.0.9: app wiring")
struct Audit109WiringTests {
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

    @Test("Where the app reads a session's file, the file decides whether a turn failed")
    func transcriptDecidesFailure() throws {
        let model = try Self.source("Sources/ChimloApp/ApplicationModel.swift")

        // A hook's failure report cannot tell the owner's turn from a request
        // Claude Code made by itself, so it is not applied for these sessions.
        let live = try Self.body(of: "private func receiveLiveEvent(_ reported: AgentEvent) {", in: model)
        let dropped = try #require(live.range(of: "if reported.kind == .failed, sessionsWithTranscript.contains(reported.sessionID) { return }"))
        let consumed = try #require(live.range(of: "consume("))
        #expect(dropped.lowerBound < consumed.lowerBound)

        // The session file's own record of a failed turn is announced once,
        // when it is fresh, through the same path as any failure.
        let merged = try Self.body(of: "private func receive(_ candidate: SessionCandidate) {", in: model)
        #expect(merged.contains("if candidate.evidence == .claudeTranscript { sessionsWithTranscript.insert(candidate.id) }"))
        #expect(merged.contains("&& merged.phase == .failed"))
        #expect(merged.contains("&& previous?.phase != .failed"))
        #expect(merged.contains("candidate.updatedAt >= Date.now.addingTimeInterval(-Self.freshFailureSeconds)"))
        #expect(merged.contains("kind: .failed,"))
        #expect(try Self.body(of: "private func removeSession(_ sessionID: String) {", in: model)
            .contains("sessionsWithTranscript.remove(sessionID)"))
    }

    @Test("A failure opens the notch only if the owner lets failures show in the notch")
    func failureRespectsNotificationSetting() throws {
        let model = try Self.source("Sources/ChimloApp/ApplicationModel.swift")
        let consume = try Self.body(of: "private func consume(_ event: AgentEvent) {", in: model)
        #expect(consume.contains("if event.kind == .failed, let decision { failureMayOpenNotch = decision.showInNotch }"))
        #expect(consume.contains("(session.pendingRequest != nil || (session.phase == .failed && failureMayOpenNotch))"))
    }

    @Test("A request id that is already waiting is refused, and an answered card is always redrawn")
    func requestBookkeeping() throws {
        let model = try Self.source("Sources/ChimloApp/ApplicationModel.swift")
        #expect(model.contains("permissionRequests[request.id] == nil,"))
        #expect(model.contains("questionFlows[request.id] == nil,"))
        // Rebuilt after the "resolved" event whether or not it was applied.
        #expect(!model.contains("        } else {\n            syncSessionProjections()\n        }\n\n        let continuation = permissionContinuations"))
        let finish = try Self.body(of: "private func finishPermission(", in: model)
        let resolved = try #require(finish.range(of: "kind: .permissionResolved,"))
        let rebuilt = try #require(finish.range(of: "syncSessionProjections()"))
        #expect(resolved.lowerBound < rebuilt.lowerBound)
    }

    @Test("Anything that moves the cards re-arms the click guard, and nothing opens behind a card")
    func cardsAndPanels() throws {
        let model = try Self.source("Sources/ChimloApp/ApplicationModel.swift")
        #expect(model.contains("didSet { if showsUsageDetails != oldValue { clickGuard.cardsMoved(at: Self.uptime) } }"))
        #expect(try Self.body(of: "func revealAllSessions() {", in: model).contains("clickGuard.cardsMoved(at: Self.uptime)"))
        #expect(try Self.body(of: "func inspect(_ session: SessionDisplayModel) {", in: model).contains("guard !hasActiveOwnerInteraction,"))
        #expect(try Self.body(of: "func openCharacterPicker(for session: SessionDisplayModel) {", in: model)
            .contains("guard canPickCharacter(for: session)"))
    }

    @Test("Deny has no key either, and a failed session can be archived")
    func cardKeysAndArchive() throws {
        let views = try Self.source("Sources/ChimloApp/IslandViews.swift")
        // Escape stays on the answer field's own cancel and the stand-alone
        // decision; a permission card answers to clicks only.
        let card = try #require(views.range(of: #"Button("Deny") {"#))
        let afterDeny = views[card.upperBound...].prefix(600)
        #expect(!afterDeny.contains(".keyboardShortcut("))
        #expect(!views.contains(".keyboardShortcut(.defaultAction)"))
        // Only a session with a card open cannot be put away.
        #expect(views.contains("onArchive: session.hasActiveOwnerInteraction\n"))
        #expect(!views.contains("onArchive: session.needsAttention"))
    }

    @Test("The card says what Allow All covers")
    func allowAllScopeIsShown() throws {
        let views = try Self.source("Sources/ChimloApp/IslandViews.swift")
        #expect(views.contains("if let scope = SessionPermissionPresentation.scopeLine(for: request) {"))
        let model = try Self.source("Sources/ChimloApp/ApplicationModel.swift")
        #expect(model.contains(#"return "Allow All covers \(scope)""#))
        #expect(model.contains("scopeLineCount: scopeLineCount"))
    }

    @Test("The helper copy loses its quarantine flag, and a failed repair leaves working hooks alone")
    func installSafety() throws {
        let integration = try Self.source("Sources/ChimloApp/AgentIntegrationManager.swift")
        #expect(integration.contains(#"removexattr($0, "com.apple.quarantine", 0)"#))
        #expect(integration.components(separatedBy: "Self.removeQuarantine(from:").count - 1 == 2)

        let setup = try Self.source("Sources/ChimloApp/SetupCoordinator.swift")
        #expect(setup.contains(##"contains("# overhead-claude-")"##))
        #expect(setup.contains("if after != before, !wasConnected {"))
    }

    @Test("Views ask whether a token is stored without reading it")
    func tokenPresenceNeverBlocks() throws {
        let github = try Self.source("Sources/ChimloApp/GitHubModel.swift")
        let stored = try Self.body(of: "var hasStoredToken: Bool {", in: github)
        #expect(stored.contains("tokenStore.exists()"))
        #expect(!stored.contains("read()"))

        let store = try Self.source("Sources/ChimloCore/KeychainTokenStore.swift")
        let exists = try Self.body(of: "public func exists() -> Bool {", in: store)
        #expect(exists.contains("kSecReturnAttributes"))
        #expect(!exists.contains("kSecReturnData"))
    }

    @Test("Nothing on GitHub builds or tests; the release command runs the packaged binaries itself")
    func releaseRunsThePackagedBinaries() throws {
        // No workflows: every check a release gets, it gets from the release command.
        let workflows = Self.root.appendingPathComponent(".github/workflows").path
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: workflows)) ?? []).isEmpty)

        // The helper Claude Code's hooks call, and the app's own binary, are
        // run from the packaged app before anything is published.
        let release = try Self.source("Scripts/public-release.sh")
        let helper = try #require(release.range(of: #""dist/Claude Overhead.app/Contents/Helpers/overhead" help >/dev/null"#))
        let draws = try #require(release.range(of: #"./Scripts/check-release-notes.sh --release "$TAG" --app "dist/Claude Overhead.app""#))
        let publish = try #require(release.range(of: #"./Scripts/publish-github-release.sh "$TAG""#))
        #expect(helper.lowerBound < publish.lowerBound)
        #expect(draws.lowerBound < publish.lowerBound)
        #expect(!release.contains("gh run list"))

        // Starting the app in full is left to a machine with no data of its
        // own; the tool for it starts the app and waits for its helper.
        let script = try Self.source("Scripts/smoke-launch.sh")
        #expect(script.contains(#""$HELPER" ping"#))
        #expect(script.contains("CHIMLO_RUNTIME_DESCRIPTOR"))
    }
}
