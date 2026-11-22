import Foundation

/// Where this Mac's Claude Code lives, if anywhere.
///
/// Overhead connects through `~/.claude/settings.json`, which every Claude
/// Code surface reads: the command line, the VS Code and JetBrains extensions,
/// and the Desktop app. So the settings folder alone counts as installed, even
/// with no `claude` executable anywhere.
public struct ClaudeCodeInstallation: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case commandLine
        case editorExtension
        case settingsFolder
    }

    public let source: Source
    public let path: String

    public init(source: Source, path: String) {
        self.source = source
        self.path = path
    }

    public var summary: String {
        switch source {
        case .commandLine: "Claude Code command line"
        case .editorExtension: "Claude Code editor extension"
        case .settingsFolder: "Claude Code settings"
        }
    }
}

public enum ClaudeCodeLocator {
    /// `claude` executables worth trying, in order: the PATH first, then where
    /// the native installer, Homebrew, and the older local installer put it.
    /// An app opened from Finder gets a minimal PATH, so the fixed list matters.
    public static func executableCandidates(home: String, path: String?) -> [String] {
        var candidates = (path ?? "")
            .split(separator: ":")
            .map { "\($0)/claude" }
        candidates += [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func extensionRoots(home: String) -> [String] {
        [".vscode", ".vscode-insiders", ".cursor", ".windsurf"]
            .map { "\(home)/\($0)/extensions" }
    }

    static let extensionPrefix = "anthropic.claude-code-"

    public static func detect(
        home: String,
        path: String?,
        isExecutable: (String) -> Bool,
        directoryExists: (String) -> Bool,
        contentsOfDirectory: (String) -> [String]
    ) -> ClaudeCodeInstallation? {
        if let executable = executableCandidates(home: home, path: path).first(where: isExecutable) {
            return ClaudeCodeInstallation(source: .commandLine, path: executable)
        }
        for root in extensionRoots(home: home) where directoryExists(root) {
            if let name = contentsOfDirectory(root).sorted().last(where: { $0.hasPrefix(extensionPrefix) }) {
                return ClaudeCodeInstallation(source: .editorExtension, path: "\(root)/\(name)")
            }
        }
        let settings = "\(home)/.claude"
        if directoryExists(settings) {
            return ClaudeCodeInstallation(source: .settingsFolder, path: settings)
        }
        return nil
    }

    public static func detect(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeCodeInstallation? {
        detect(
            home: fileManager.homeDirectoryForCurrentUser.path,
            path: environment["PATH"],
            isExecutable: { fileManager.isExecutableFile(atPath: $0) },
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            },
            contentsOfDirectory: { (try? fileManager.contentsOfDirectory(atPath: $0)) ?? [] }
        )
    }
}
