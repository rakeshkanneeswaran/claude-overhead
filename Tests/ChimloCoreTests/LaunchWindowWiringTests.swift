import Foundation
import Testing

/// Claude Overhead 1.1.0 and earlier opened an old settings window by itself
/// when the app was started from Spotlight or the Dock, or after a restart.
/// The app declared one SwiftUI scene, a `Settings` scene left over from
/// before the companion window existed, and SwiftUI presents an app's only
/// scene at launch when that scene has a window. The app target has no tests
/// of its own, so these read its source and pin the fix.
@Suite("Launch: no window opens by itself")
struct LaunchWindowWiringTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let app = root.appendingPathComponent("Sources/ChimloApp")

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) is missing")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    @Test("The app declares no scene that has a window")
    func noWindowScene() throws {
        let scenes = try Self.body(of: "var body: some Scene {", in: try Self.source("ChimloApp.swift"))
        // The one scene SwiftUI requires is a menu bar extra that is never inserted.
        #expect(scenes.contains(#"MenuBarExtra("Claude Overhead", isInserted: .constant(false)) {"#))
        for windowScene in ["Settings {", "WindowGroup", "Window(", "DocumentGroup"] {
            #expect(!scenes.contains(windowScene), "\(windowScene) would be presented when the app starts")
        }
        // And no other file declares one.
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.app.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count > 20)
        for file in files {
            let text = try Self.source(file)
            #expect(!text.contains("some Scene") || file == "ChimloApp.swift", "\(file) declares a scene")
        }
    }

    @Test("Command-comma opens Settings in the companion window")
    func commandComma() throws {
        let appSource = try Self.source("ChimloApp.swift")
        let scenes = try Self.body(of: "var body: some Scene {", in: appSource)
        #expect(scenes.contains("CommandGroup(replacing: .appSettings) {"))
        #expect(scenes.contains(#"Button("Settings…") { appDelegate.showSettings() }"#))
        #expect(scenes.contains(#".keyboardShortcut(",", modifiers: .command)"#))
        let show = try Self.body(of: "func showSettings() {", in: appSource)
        #expect(show.contains("companionCoordinator.show(.settings)"))
    }
}
