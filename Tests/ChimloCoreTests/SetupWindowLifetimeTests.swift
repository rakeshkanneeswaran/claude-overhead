import Foundation
import Testing

/// A closed window that is kept keeps its SwiftUI content mounted, and SwiftUI
/// keeps running that content's animations off screen. Through 1.0.6 the setup
/// window was kept after closing, so its storyboard's 60 fps colour wave cost
/// 6 to 20% of a core for as long as the app ran after onboarding. The app
/// target has no tests of its own, so this reads its source.
@Suite("Setup window lifetime")
struct SetupWindowLifetimeTests {
    private static let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp/SetupCoordinator.swift")

    @Test("Closing the setup window releases it and its content")
    func closingReleasesTheWindow() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let start = try #require(text.range(of: "func windowWillClose("))
        // The method's body: up to the next line that closes a member at
        // type-member indentation.
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])

        #expect(body.contains("window = nil"), "windowWillClose must drop the coordinator's reference")
        #expect(body.contains("contentView = nil"), "windowWillClose must unmount the SwiftUI content")
    }

    @Test("The setup window is rebuilt when it is shown again")
    func showingRebuildsTheWindow() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let start = try #require(text.range(of: "private func showWindow()"))
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])

        #expect(body.contains("if window == nil"))
        #expect(body.contains("NSHostingView(rootView: SetupWindowView(setup: self))"))
    }
}
