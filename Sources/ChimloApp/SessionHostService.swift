import AppKit
import ChimloCore
import Foundation

/// The app that hosts a running Claude session, worked out from the live
/// process: its terminal device, its parent apps, or the editor extension it
/// runs from. Resolved on demand when the owner asks, never polled.
struct SessionHost: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Terminal.app or iTerm2: the exact tab can be selected by its tty.
        case terminalTab(bundleID: String, tty: String)
        /// A VS Code-family editor: reopening the project brings its window forward.
        case editorWindow(bundleID: String, projectPath: String)
        /// Any other host: only the app can be brought forward.
        case app(processID: Int32)
    }

    let kind: Kind
    let name: String

    /// How precise focusing will be, for an honest button label.
    var actionTitle: String {
        switch kind {
        case .terminalTab: "Show in \(name)"
        case .editorWindow: "Open in \(name)"
        case .app: "Switch to \(name)"
        }
    }
}

enum SessionHostService {
    private static let terminals: [(fragment: String, bundleID: String, name: String)] = [
        ("terminal.app", "com.apple.Terminal", "Terminal"),
        ("iterm.app", "com.googlecode.iterm2", "iTerm"),
    ]

    private static let editors: [(fragment: String, bundleID: String, name: String)] = [
        ("/.vscode-insiders/extensions/", "com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("/.vscode/extensions/", "com.microsoft.VSCode", "VS Code"),
        ("/.cursor/extensions/", "com.todesktop.230313mzl4w4u92", "Cursor"),
        ("/.windsurf/extensions/", "com.exafunction.windsurf", "Windsurf"),
    ]

    /// Finds the live Claude process working in `projectPath` and the app that
    /// hosts it. Nil when no live process is found, which is also what tells
    /// session recovery that resuming is safe.
    static func resolve(projectPath: String?) async -> SessionHost? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            resolveSynchronously(projectPath: projectPath)
        }.value
    }

    nonisolated private static func resolveSynchronously(projectPath: String) -> SessionHost? {
        guard let output = LocalAgentProcessDiscovery.commandOutput(
            executable: "/bin/ps",
            arguments: ["-Ao", "pid=,ppid=,tty=,command="]
        ) else { return nil }
        let processes = output.split(whereSeparator: \.isNewline)
            .compactMap(LocalAgentProcessDiscovery.ProcessLine.init)
        let byID = Dictionary(processes.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
        let target = URL(fileURLWithPath: projectPath).standardizedFileURL.path

        let candidates = processes.filter(isClaudeProcess).sorted { $0.processID > $1.processID }
        for process in candidates {
            guard workingDirectory(of: process.processID) == target else { continue }
            if let host = host(for: process, byID: byID, projectPath: target) { return host }
        }
        return nil
    }

    nonisolated private static func isClaudeProcess(_ process: LocalAgentProcessDiscovery.ProcessLine) -> Bool {
        let executable = process.command.split(separator: " ").first.map(String.init) ?? process.command
        return executable == "claude" || executable.hasSuffix("/claude")
    }

    nonisolated private static func workingDirectory(of processID: Int32) -> String? {
        guard let output = LocalAgentProcessDiscovery.commandOutput(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", "\(processID)", "-d", "cwd", "-Fn"]
        ) else { return nil }
        return output.split(whereSeparator: \.isNewline)
            .first { $0.first == "n" }
            .map { URL(fileURLWithPath: String($0.dropFirst())).standardizedFileURL.path }
    }

    nonisolated private static func host(
        for process: LocalAgentProcessDiscovery.ProcessLine,
        byID: [Int32: LocalAgentProcessDiscovery.ProcessLine],
        projectPath: String
    ) -> SessionHost? {
        // Editor extensions run Claude from their extension folder, so the
        // binary's own path names the editor, with or without a tty.
        let path = process.command.lowercased()
        if let editor = editors.first(where: { path.contains($0.fragment) }) {
            return SessionHost(kind: .editorWindow(bundleID: editor.bundleID, projectPath: projectPath), name: editor.name)
        }

        var parentID = process.parentID
        var visited = Set<Int32>()
        while parentID > 1, visited.insert(parentID).inserted, let parent = byID[parentID] {
            let command = parent.command.lowercased()
            if let terminal = terminals.first(where: { command.contains($0.fragment) }),
               let tty = process.tty, isTerminalDevice(tty) {
                return SessionHost(kind: .terminalTab(bundleID: terminal.bundleID, tty: "/dev/\(tty)"), name: terminal.name)
            }
            if let app = NSRunningApplication(processIdentifier: parent.processID),
               app.activationPolicy == .regular {
                return SessionHost(kind: .app(processID: parent.processID), name: app.localizedName ?? "its app")
            }
            parentID = parent.parentID
        }
        return nil
    }

    /// Only plain `ttysNNN` names reach AppleScript, so nothing from a process
    /// table can be interpreted as script.
    nonisolated static func isTerminalDevice(_ tty: String) -> Bool {
        tty.hasPrefix("ttys") && tty.dropFirst(4).allSatisfy(\.isNumber) && tty.count > 4
    }

    /// Brings the host forward. Returns false when it could not, so the caller
    /// never claims a focus that did not happen.
    @MainActor
    static func focus(_ host: SessionHost) async -> Bool {
        switch host.kind {
        case let .terminalTab(bundleID, tty):
            let script = bundleID == "com.googlecode.iterm2" ? iTermScript(tty: tty) : terminalScript(tty: tty)
            return await runAppleScript(script)
        case let .editorWindow(bundleID, projectPath):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open(
                    [URL(fileURLWithPath: projectPath)],
                    withApplicationAt: appURL,
                    configuration: configuration
                )
                return true
            } catch {
                return false
            }
        case let .app(processID):
            return NSRunningApplication(processIdentifier: processID)?.activate() ?? false
        }
    }

    nonisolated private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    if tty of theTab is "\(tty)" then
                        set selected of theTab to true
                        set index of theWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    nonisolated private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    repeat with theSession in sessions of theTab
                        if tty of theSession is "\(tty)" then
                            select theWindow
                            tell theTab to select
                            tell theSession to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    /// Runs off the main thread: Apple events can wait on the target app.
    private static func runAppleScript(_ source: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error == nil && result?.booleanValue == true
        }.value
    }

    // MARK: Resume

    /// Opens Terminal and resumes the session with Claude Code's own
    /// `--resume`, in the project folder. Only offered when no live process
    /// still holds the session, so two clients never write one transcript.
    @MainActor
    static func resumeInTerminal(sessionID: String, projectPath: String?, claudeExecutable: String) async -> Bool {
        guard UUID(uuidString: sessionID) != nil else { return false }
        var command = "\(shellQuoted(claudeExecutable)) --resume \(sessionID)"
        if let projectPath, !projectPath.isEmpty {
            command = "cd \(shellQuoted(projectPath)) && " + command
        }
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(command))"
        end tell
        return true
        """
        return await runAppleScript(script)
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
