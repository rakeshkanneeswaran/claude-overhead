import Foundation
import Testing

/// Setup ends in the real notch. There used to be a tour after it, played
/// with a made-up session and a made-up permission request, and a placeholder
/// session shown when the app could not listen. Both are gone; the app has no
/// tests of its own, so these read its source and pin that nothing made up is
/// shown as a session again.
@Suite("First run: no demo")
struct FirstRunWiringTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let app = root.appendingPathComponent("Sources/ChimloApp")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
    }

    private static func appSources() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) is missing")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    @Test("The app has no tour, no demo session and no placeholder session")
    func nothingMadeUp() throws {
        #expect(!FileManager.default.fileExists(atPath: Self.app.appendingPathComponent("OnboardingView.swift").path))

        let sources = try Self.appSources()
        #expect(sources.count > 20)
        let gone = [
            "isDemo", "DemoScript", "beginOnboardingDemo", "resolveDemoPermission",
            "installPreviewSession", "keepPreviewSession", "OnboardingView", "OnboardingStep",
            "case onboarding", "Demo only", "DEMO RUNNING", "Local listener preview",
        ]
        for (name, text) in sources {
            for word in gone {
                #expect(!text.contains(word), "\(name) still mentions \(word)")
            }
        }
    }

    @Test("Every session the notch lists comes from Claude Code")
    func sessionsAreReal() throws {
        let model = try Self.source("ApplicationModel.swift")
        // One way in for an event, and it has no "this one is made up" flag.
        #expect(model.contains("private func consume(_ event: AgentEvent) {"))
        #expect(!model.contains("isDemo:"))
        // The model builds a session event itself in four places only: the
        // start it infers for a session first heard of mid-turn, a failed turn
        // read from the session's file, and the owner's answer to a
        // permission card or a question.
        #expect(model.components(separatedBy: "consume(\n            AgentEvent(").count - 1
            + model.components(separatedBy: "consume(\n                AgentEvent(").count - 1 == 4)
    }

    @Test("\"See your notch\" opens the real notch once, and only after a verified connection")
    func setupEndsInTheRealNotch() throws {
        let delegate = try Self.source("ChimloApp.swift")
        #expect(delegate.contains("if revealNotch { model.revealNotchAfterSetup() }"))

        let coordinator = try Self.source("SetupCoordinator.swift")
        #expect(coordinator.contains("let revealNotch = closesIntoNotch && flow.isComplete"))

        let model = try Self.source("ApplicationModel.swift")
        let reveal = try Self.body(of: "func revealNotchAfterSetup() {", in: model)
        #expect(reveal.contains("openPanel()"))
        #expect(reveal.contains("scheduleCollapseAfterHover(delayMilliseconds: Self.glanceMilliseconds)"))
        #expect(!reveal.contains("consume("))
    }

    @Test("Someone who finished setup on an earlier version is not sent through it again")
    func setupCompletionIsKept() throws {
        let model = try Self.source("ApplicationModel.swift")
        // The same stored key 1.0.0 to 1.0.8 wrote.
        #expect(model.contains(#"static let completedOnboarding = "overhead.onboarding.completed""#))
        #expect(model.contains("var hasCompletedSetup: Bool { defaults.bool(forKey: Keys.completedOnboarding) }"))
        let mark = try Self.body(of: "func markSetupCompleted() {", in: model)
        #expect(mark.contains("defaults.set(true, forKey: Keys.completedOnboarding)"))
    }

    @Test("An empty notch says so when the app cannot listen for Claude Code")
    func listenerFailureIsSaid() throws {
        let views = try Self.source("IslandViews.swift")
        #expect(views.contains("if case .failed = model.serverState { return true }"))
        #expect(views.contains(#"if listenerFailed, model.hasInstalledAgent { return "Claude Overhead can't listen right now" }"#))
    }
}
