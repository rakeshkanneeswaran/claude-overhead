import Foundation
import Testing
@testable import ChimloCore

/// A request from a run nobody is watching is left to Claude Code unless the
/// owner asked to hear about those. The helper reports what it found about
/// the run; the app, which holds the setting, decides.
@Suite("Unattended runs")
struct UnattendedRunTests {
    private static let permissionPayload = Data(
        #"{"session_id":"run-02","hook_event_name":"PermissionRequest","permission_mode":"default","tool_name":"Bash","cwd":"/Users/me/experiment/opus-low-02","tool_input":{"command":"cd implementation; grep -n EXP index.html"}}"#.utf8
    )

    private static let questionPayload = Data(
        #"{"session_id":"run-02","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","cwd":"/Users/me/experiment/opus-low-02","tool_input":{"questions":[{"question":"Which one?","header":"Pick","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}}"#.utf8
    )

    // MARK: The decision

    @Test("An attended run always reaches the notch; an unattended one only when asked for")
    func policy() {
        #expect(UnattendedRunPolicy.reachesNotch(isUnattended: false, ownerAsksAboutUnattendedRuns: false))
        #expect(UnattendedRunPolicy.reachesNotch(isUnattended: false, ownerAsksAboutUnattendedRuns: true))
        #expect(!UnattendedRunPolicy.reachesNotch(isUnattended: true, ownerAsksAboutUnattendedRuns: false))
        #expect(UnattendedRunPolicy.reachesNotch(isUnattended: true, ownerAsksAboutUnattendedRuns: true))
    }

    @Test("The setting is off unless the owner turns it on, and survives a save")
    func setting() throws {
        #expect(!OverheadSettings().askAboutUnattendedRuns)

        // A settings file written before the setting existed.
        let older = try JSONDecoder().decode(OverheadSettings.self, from: Data(#"{"version":1,"notchLocked":true}"#.utf8))
        #expect(!older.askAboutUnattendedRuns)
        #expect(older.notchLocked)

        var settings = OverheadSettings()
        settings.askAboutUnattendedRuns = true
        let saved = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(OverheadSettings.self, from: saved).askAboutUnattendedRuns)

        // An unreadable value falls back to off, never to on.
        let damaged = try JSONDecoder().decode(
            OverheadSettings.self,
            from: Data(#"{"askAboutUnattendedRuns":"yes"}"#.utf8)
        )
        #expect(!damaged.askAboutUnattendedRuns)
    }

    // MARK: What the helper sends

    @Test("A permission request carries the mode and whether the run is unattended")
    func permissionRequestFields() throws {
        let attended = try ClaudePermissionHook(data: Self.permissionPayload)
        #expect(!attended.request.isUnattended)
        #expect(attended.request.permissionMode == "default")
        #expect(attended.request.title == "opus-low-02")

        let unattended = try ClaudePermissionHook(data: Self.permissionPayload, isUnattended: true)
        #expect(unattended.request.isUnattended)
        // Being unattended changes who is asked, never what an answer means.
        #expect(unattended.asksOwner)
        let allowed = unattended.output(for: ProviderPermissionResponse(requestID: unattended.request.id, outcome: .allowedOnce))
        #expect(String(decoding: allowed, as: UTF8.self).contains(#""behavior":"allow""#))
    }

    @Test("Left to Claude Code, an unattended request is answered with the no-op and grants nothing")
    func leftToClaudeCode() throws {
        let hook = try ClaudePermissionHook(data: Self.permissionPayload, isUnattended: true)
        let output = hook.output(for: .unavailable(for: hook.request.id, reason: "Unattended run: left to Claude Code"))
        #expect(output == ClaudePermissionHook.fallbackOutput)
        #expect(!String(decoding: output, as: UTF8.self).contains("allow"))

        let question = try ClaudeQuestionHook(data: Self.questionPayload, isUnattended: true)
        #expect(question.request.isUnattended)
        let unanswered = question.output(for: .unavailable(for: question.request.id, reason: "Unattended run: left to Claude Code"))
        #expect(unanswered == ClaudeQuestionHook.fallbackOutput)
    }

    @Test("A question request is attended unless the helper says otherwise")
    func questionRequestFields() throws {
        #expect(try !ClaudeQuestionHook(data: Self.questionPayload).request.isUnattended)
    }

    // MARK: Old helper, new app (and the other way round)

    @Test("A request from a helper older than the app reads as attended, in an unnamed mode")
    func olderHelper() throws {
        let decoder = JSONDecoder()
        let permission = try decoder.decode(ProviderPermissionRequest.self, from: Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sessionID":"s","agent":"claude","title":"t","toolName":"Bash","prompt":"p","allowsSessionApproval":true}"#.utf8
        ))
        #expect(!permission.isUnattended)
        #expect(permission.permissionMode == nil)
        #expect(permission.allowsSessionApproval)

        let question = try decoder.decode(ProviderQuestionRequest.self, from: Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","sessionID":"s","agent":"claude","title":"t","questions":[]}"#.utf8
        ))
        #expect(!question.isUnattended)
    }

    @Test("The new fields survive the wire encoding")
    func roundTrip() throws {
        let permission = ProviderPermissionRequest(
            sessionID: "s", agent: .claude, title: "t", toolName: "Bash", prompt: "p",
            permissionMode: "auto", isUnattended: true
        )
        let decodedPermission = try JSONDecoder().decode(
            ProviderPermissionRequest.self,
            from: JSONEncoder().encode(permission)
        )
        #expect(decodedPermission == permission)

        let question = ProviderQuestionRequest(sessionID: "s", agent: .claude, title: "t", questions: [], isUnattended: true)
        #expect(try JSONDecoder().decode(ProviderQuestionRequest.self, from: JSONEncoder().encode(question)) == question)
    }

    // MARK: The card's label

    @Test("Modes are shown under the names Claude Code uses, and unknown ones not at all")
    func modeNames() {
        #expect(ClaudePermissionModeName.displayName(for: "default") == "Manual")
        #expect(ClaudePermissionModeName.displayName(for: "auto") == "Auto")
        #expect(ClaudePermissionModeName.displayName(for: "plan") == "Plan")
        #expect(ClaudePermissionModeName.displayName(for: "acceptEdits") == "Accept edits")
        #expect(ClaudePermissionModeName.displayName(for: "aModeAddedLater") == nil)
        #expect(ClaudePermissionModeName.displayName(for: "") == nil)
        #expect(ClaudePermissionModeName.displayName(for: nil) == nil)
    }

    // MARK: The app and helper targets, which have no tests of their own

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of a function from its signature to the next member at the
    /// same indentation.
    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) is missing")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    @Test("The app decides about an unattended request before it stores or shows anything")
    func appChecksBeforePresenting() throws {
        let model = try Self.source("ChimloApp/ApplicationModel.swift")

        let permission = try Self.body(of: "private func requestPermission(", in: model)
        let permissionCheck = try #require(permission.range(of: "UnattendedRunPolicy.reachesNotch("))
        let permissionStored = try #require(permission.range(of: "permissionRequests[request.id] = request"))
        #expect(permissionCheck.lowerBound < permissionStored.lowerBound)
        #expect(permission.contains("isUnattended: request.isUnattended"))
        #expect(permission.contains("ownerAsksAboutUnattendedRuns: asksAboutUnattendedRuns"))

        let question = try Self.body(of: "private func requestQuestion(", in: model)
        let questionCheck = try #require(question.range(of: "UnattendedRunPolicy.reachesNotch("))
        let questionStored = try #require(question.range(of: "questionFlows[request.id] = flow"))
        #expect(questionCheck.lowerBound < questionStored.lowerBound)

        // The model's copy follows the owner's setting.
        #expect(model.contains("asksAboutUnattendedRuns = settings.askAboutUnattendedRuns"))
        // Off until the settings say otherwise.
        #expect(model.contains("private var asksAboutUnattendedRuns = false"))
    }

    @Test("The helper reports the launch for both blocking hooks")
    func helperReportsTheLaunch() throws {
        let helper = try Self.source("ChimloCLI/main.swift")
        for function in ["answerClaudeQuestionHook()", "answerClaudePermissionHook()"] {
            let body = try Self.body(of: "private static func \(function) async {", in: helper)
            #expect(body.contains("isUnattended: ClaudeLaunch.current().isUnattended"), "\(function)")
        }
    }

    @Test("The card names the session's mode, and the setting has a switch")
    func cardAndSetting() throws {
        let views = try Self.source("ChimloApp/IslandViews.swift")
        #expect(views.contains("ClaudePermissionModeName.displayName(for: request.permissionMode)"))
        #expect(views.contains("request.isUnattended"))

        let settings = try Self.source("ChimloApp/CompanionSettings.swift")
        #expect(settings.contains(#"settings.binding(\.askAboutUnattendedRuns)"#))
    }
}
