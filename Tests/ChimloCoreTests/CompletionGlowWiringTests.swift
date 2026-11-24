import Foundation
import Testing

/// The glow's app half lives in the app target, which has no tests of its
/// own, so this reads its source (as `SessionCharacterWiringTests` does). It
/// pins what is easy to break later: the glow has one trigger and one
/// switch, off means nothing runs, and neither the glow nor the sound path
/// reads the other's settings.
@Suite("Completion glow: app wiring")
struct CompletionGlowWiringTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    private static func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) is missing")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("A finished turn is still what starts the glow, and it starts it once")
    func oneTrigger() throws {
        let model = try Self.source("ApplicationModel.swift")
        let consume = try Self.body(of: "private func consume(_ event: AgentEvent) {", in: model)
        #expect(consume.contains("if isNewCompletion { flashCompletionGlow() }"))
        #expect(Self.count("flashCompletionGlow()", in: consume) == 1)
        // Its definition, the finished turn, and Settings' preview: nowhere else.
        #expect(Self.count("flashCompletionGlow()", in: model) == 3)
        let preview = try Self.body(of: "func previewCompletionGlow() {", in: model)
        #expect(preview.trimmingCharacters(in: .whitespacesAndNewlines) == "flashCompletionGlow()")
        // Completion itself is detected as before.
        #expect(consume.contains("IslandCollapsePolicy.isNewCompletion("))
    }

    @Test("Switched off, nothing is started: no state changes and no timer")
    func offStartsNothing() throws {
        let model = try Self.source("ApplicationModel.swift")
        let flash = try Self.body(of: "private func flashCompletionGlow() {", in: model)
        let lines = flash.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.first == "guard completionGlow != nil else { return }")
        // One glow at a time: the running one is cancelled before the next.
        #expect(flash.contains("completionGlowTask?.cancel()"))
        #expect(Self.count("completionGlowTask = Task", in: model) == 1)
    }

    @Test("Turning the glow off stops one that is showing, and quitting cancels its timer")
    func offAndQuitCleanUp() throws {
        let model = try Self.source("ApplicationModel.swift")
        let apply = try Self.body(of: "func applySettings(_ settings: OverheadSettings, now: Date = .now) {", in: model)
        #expect(apply.contains("completionGlow = settings.completionGlow"))
        #expect(apply.contains("if completionGlow == nil { clearCompletionGlow() }"))
        let clear = try Self.body(of: "private func clearCompletionGlow() {", in: model)
        #expect(clear.contains("completionGlowTask?.cancel()"))
        #expect(clear.contains("showsCompletionGlow = false"))
        #expect(clear.contains("animatesCompletionGlow = false"))
        let stop = try Self.body(of: "func stop() {", in: model)
        #expect(stop.contains("completionGlowTask?.cancel()"))
    }

    @Test("The glow never reads a sound setting, and the sound never reads the glow")
    func glowAndSoundDoNotMeet() throws {
        let model = try Self.source("ApplicationModel.swift")
        for signature in ["private func flashCompletionGlow() {", "private func clearCompletionGlow() {", "func previewCompletionGlow() {"] {
            let body = try Self.body(of: signature, in: model).lowercased()
            #expect(!body.contains("sound"), "\(signature) reads sound")
            #expect(!body.contains("announce"), "\(signature) announces")
        }
        for signature in [
            "private func announceCompletionIfNeeded(sessionID: String, receivedAt: Date) {",
            "private func playSound(_ cue: ChiptuneCue) {",
            "func toggleSound(for sessionID: String) {",
        ] {
            let body = try Self.body(of: signature, in: model)
            #expect(!body.contains("Glow"), "\(signature) reads the glow")
        }
        // The sound decision: the policy and that session's bell, nothing else.
        let start = try #require(model.range(of: "    private func announce(\n"))
        let end = try #require(model[start.upperBound...].range(of: "\n    }\n"))
        let announce = String(model[start.upperBound..<end.lowerBound])
        #expect(announce.contains("soundGate.allows("))
        #expect(!announce.contains("Glow"))
    }

    @Test("The notch makes a glow view only while a glow shows, in the owner's theme")
    func notchDrawsTheChosenTheme() throws {
        let views = try Self.source("IslandViews.swift")
        #expect(views.contains("if model.animatesCompletionGlow, let glow = model.completionGlow {"))
        #expect(views.contains("CompletionGlowFill(shape: shape, theme: glow.theme, flows: !model.reducesMotion)"))
        #expect(views.contains(".opacity(model.showsCompletionGlow ? glow.brightness : 0)"))
        // Only the closed notch carries it, as before.
        #expect(Self.count("completionGlow(in:", in: views) == 2)

        // The wave's own view is gone: every glow is drawn through one view.
        for file in ["IslandViews.swift", "SetupIllustrations.swift", "CompanionSettings.swift"] {
            #expect(!(try Self.source(file)).contains("SpectrumWaveFill"))
        }
    }

    @Test("A glow that must not move is drawn once and its timeline is paused")
    func stillMeansPaused() throws {
        let glow = try Self.source("CompletionGlowViews.swift")
        #expect(glow.contains("let moves = flows && theme.isAnimated"))
        #expect(glow.contains("TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moves))"))
        #expect(glow.contains("theme.layers(at: moves ? context.date.timeIntervalSinceReferenceDate : nil)"))
        #expect(glow.contains(".allowsHitTesting(false)"))
        #expect(glow.contains(".accessibilityHidden(true)"))
    }

    @Test("Settings has one switch for the glow, every theme, and nothing about sound")
    func settingsSection() throws {
        let settings = try Self.source("CompanionSettings.swift")
        let start = try #require(settings.range(of: "private struct CompletionGlowSection: View {"))
        let end = try #require(settings.range(of: "struct ClaudeConnectionRow: View {"))
        let section = String(settings[start.upperBound..<end.lowerBound])
        #expect(section.contains("Toggle(\"Glow when Claude finishes a turn\""))
        #expect(section.contains("settings.settings.setCompletionGlowEnabled($0)"))
        #expect(section.contains("ForEach(GlowTheme.allCases) { theme in"))
        #expect(section.contains("settings.settings.completionGlowTheme = theme"))
        #expect(section.contains("model.previewCompletionGlow()"))
        // The themes and brightness show only while the glow is on.
        #expect(section.contains("if isOn {"))
        // The chosen theme is marked for the eye and for VoiceOver.
        #expect(section.contains("selected: theme == chosen"))
        #expect(section.contains(".accessibilityAddTraits(theme == chosen ? .isSelected : [])"))
        // A swatch moves only when chosen or pointed at, and never against Reduce Motion.
        #expect(section.contains("flows: (theme == chosen || theme == hovered) && !model.reducesMotion"))
        // It writes no sound setting.
        #expect(!section.contains("notifications"))
        #expect(!section.contains("soundsEnabled"))
        #expect(!section.contains("toggleSound"))
        // It is on the Appearance pane, and the old slider is not a second switch.
        #expect(Self.count("CompletionGlowSection()", in: settings) == 1)
        #expect(!settings.contains("Slider(value: settings.binding(\\.glowIntensity), in: 0...1)"))

        // Nothing in the sound settings mentions the glow's switch either.
        let soundStart = try #require(settings.range(of: "private struct NotificationsPane: View {"))
        let soundEnd = try #require(settings.range(of: "struct EventPreferenceRow: View {"))
        #expect(!settings[soundStart.upperBound..<soundEnd.lowerBound].contains("completionGlow"))
    }
}
