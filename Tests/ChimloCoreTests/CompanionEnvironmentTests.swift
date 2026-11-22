import Foundation
import Testing

/// SwiftUI ends the app the moment a view reads an `@EnvironmentObject` that
/// nobody injected, and only when that code path runs, so a missing injection
/// can ship unnoticed (1.0.5 crashed on "Connect GitHub" this way). The app
/// target has no tests of its own, so this reads its source.
@Suite("Companion window environment")
struct CompanionEnvironmentTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    /// What each expression passed to `.environmentObject(…)` in the
    /// companion window is. A new injection must be added here.
    private static let injectedTypes = [
        "navigation": "CompanionNavigation",
        "services": "OverheadServices",
        "services.model": "ApplicationModel",
        "services.settings": "SettingsModel",
        "services.history": "HistoryModel",
        "services.github": "GitHubModel",
    ]

    private static func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    @Test("Every environment object a companion page declares is injected by the window")
    func everyDeclaredObjectIsInjected() throws {
        let window = try String(contentsOf: Self.appSources.appendingPathComponent("CompanionWindow.swift"), encoding: .utf8)
        let expressions = try Self.matches(#"\.environmentObject\(([A-Za-z.]+)\)"#, in: window)
        #expect(!expressions.isEmpty)
        var injected = Set<String>()
        for expression in expressions {
            let type = try #require(Self.injectedTypes[expression], "Unknown injection \(expression): add it to injectedTypes")
            injected.insert(type)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: Self.appSources.path).filter { $0.hasSuffix(".swift") }
        var declared: [String: String] = [:]
        for file in files {
            let source = try String(contentsOf: Self.appSources.appendingPathComponent(file), encoding: .utf8)
            for type in try Self.matches(#"@EnvironmentObject\s+(?:private\s+)?var\s+\w+\s*:\s*(\w+)"#, in: source) {
                declared[type] = file
            }
        }
        #expect(!declared.isEmpty)
        for (type, file) in declared {
            #expect(injected.contains(type), "\(file) reads \(type) from the environment, but the companion window never injects it")
        }
    }
}
