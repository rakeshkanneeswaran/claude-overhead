import Foundation
import Testing

/// Two rules about the notch's request cards that live in the app target,
/// which has no tests of its own, so this reads its source (as
/// `CompanionEnvironmentTests` does).
@Suite("Audit 1.0.7 UI: approving is always a click")
struct Audit107UIApprovalIsAClickTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    private static func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    /// Return is the default action. The notch panel can hold the keyboard
    /// while another app looks frontmost, so a default action on "Allow Once"
    /// or "Approve" would let a stray Return approve a request.
    @Test("No card in the notch has a default (Return) action")
    func noDefaultActionInTheNotch() throws {
        let views = try Self.source("IslandViews.swift")
        #expect(!views.contains(".keyboardShortcut(.defaultAction)"))
        #expect(!views.contains("keyboardShortcut(.return"))
    }

    /// Every action on a card names the request it was aimed at, so the
    /// model can refuse a click meant for a card that is no longer there.
    @Test("Every card action in the model takes the request it was aimed at")
    func cardActionsNameTheirRequest() throws {
        let model = try Self.source("ApplicationModel.swift")
        let actions = [
            "respondToPendingDecision", "respondToSessionPermission", "handSessionPermissionBackToClaude",
            "selectQuestionOption", "submitQuestionSelections", "beginCustomAnswer", "cancelCustomAnswer",
            "submitCustomAnswer", "answerQuestionInClaudeCode",
        ]
        for action in actions {
            let pattern = "func \(action)\\(([^)]*)\\)"
            let regex = try NSRegularExpression(pattern: pattern)
            let match = try #require(
                regex.firstMatch(in: model, range: NSRange(model.startIndex..., in: model)),
                "\(action) is missing from ApplicationModel"
            )
            let parameters = try #require(Range(match.range(at: 1), in: model).map { String(model[$0]) })
            #expect(parameters.contains("requestID: UUID"), "\(action) must take the request id the view was showing")
        }
    }
}
