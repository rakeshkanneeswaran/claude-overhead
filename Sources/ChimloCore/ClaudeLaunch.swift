import Darwin
import Foundation

/// One process as the system reports it: the path it was started from and
/// its arguments, the first being the program name.
public struct ProcessSnapshot: Equatable, Sendable {
    public let processID: Int32
    public let parentProcessID: Int32
    public let executablePath: String
    public let arguments: [String]

    public init(processID: Int32, parentProcessID: Int32, executablePath: String, arguments: [String]) {
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

/// Reads the processes above this one. Only processes of the same user can
/// be read; anything else is reported as unreadable, never guessed.
public enum ProcessInspector {
    /// Most arguments read for one process. Far above any real Claude Code
    /// command line, and it bounds the work on a damaged argument block.
    static let maximumArguments = 4_096

    public static func snapshot(of processID: Int32) -> ProcessSnapshot? {
        guard processID > 0,
              let parent = parentProcessID(of: processID),
              let block = argumentBlock(of: processID),
              let parsed = parse(argumentBlock: block) else { return nil }
        return ProcessSnapshot(
            processID: processID,
            parentProcessID: parent,
            executablePath: parsed.executablePath,
            arguments: parsed.arguments
        )
    }

    /// The parent of `processID`, then its parent, and so on, nearest first.
    /// Stops at the first process that cannot be read and before launchd.
    public static func ancestors(of processID: Int32 = getpid(), limit: Int = 8) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var seen: Set<Int32> = [processID]
        var next = parentProcessID(of: processID)
        while let current = next, current > 1, result.count < limit, seen.insert(current).inserted {
            guard let snapshot = snapshot(of: current) else { break }
            result.append(snapshot)
            next = snapshot.parentProcessID
        }
        return result
    }

    static func parentProcessID(of processID: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        // A process that does not exist succeeds with nothing written.
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func argumentBlock(of processID: Int32) -> [UInt8]? {
        var maximum: Int32 = 0
        var maximumSize = MemoryLayout<Int32>.size
        var maximumName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maximumName, UInt32(maximumName.count), &maximum, &maximumSize, nil, 0) == 0,
              maximum > 0 else { return nil }

        var block = [UInt8](repeating: 0, count: Int(maximum))
        var length = block.count
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        guard sysctl(&name, UInt32(name.count), &block, &length, nil, 0) == 0,
              length > MemoryLayout<Int32>.size, length <= block.count else { return nil }
        block.removeSubrange(length...)
        return block
    }

    /// The block the kernel keeps for a process: the argument count, the
    /// path it was started from, zero padding, then each argument ending in
    /// a zero byte. The environment follows and is never read.
    static func parse(argumentBlock block: [UInt8]) -> (executablePath: String, arguments: [String])? {
        let countSize = MemoryLayout<Int32>.size
        guard block.count > countSize else { return nil }
        let count = block.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return nil }

        var index = countSize
        let pathStart = index
        while index < block.count, block[index] != 0 { index += 1 }
        guard index < block.count else { return nil }
        let executablePath = String(decoding: block[pathStart..<index], as: UTF8.self)
        while index < block.count, block[index] == 0 { index += 1 }

        var arguments: [String] = []
        let wanted = min(Int(count), maximumArguments)
        while arguments.count < wanted, index < block.count {
            let start = index
            while index < block.count, block[index] != 0 { index += 1 }
            arguments.append(String(decoding: block[start..<index], as: UTF8.self))
            index += 1
        }
        guard !arguments.isEmpty else { return nil }
        return (executablePath, arguments)
    }
}

/// How the Claude Code process behind a hook was started, as far as it says
/// whether a person can answer its prompts.
///
/// Claude Code runs the PermissionRequest hook in two situations: when it is
/// about to show its own prompt, and when nobody can be prompted (a
/// `claude -p` run, an SDK run with no host that answers) and it would
/// otherwise deny the call at once. Its hook input does not say which. A hook
/// that waits for a click turns the second into a run that stops for minutes
/// where it used to carry on, so the notch has to tell the two apart.
///
/// Only the launch flags are looked at. Arguments are never stored, logged
/// or sent anywhere; what leaves this type is one yes-or-no answer.
public struct ClaudeLaunch: Equatable, Sendable {
    /// Set by Claude Code for itself and inherited by everything it starts.
    /// `sdk-cli` is a `claude -p` run. A run started from inside another
    /// session inherits that session's value (`claude-vscode`, say), so this
    /// is only the fallback for when the arguments cannot be read.
    public static let entrypointVariable = "CLAUDE_CODE_ENTRYPOINT"

    /// Claude Code's arguments without the program name; nil when no Claude
    /// Code process was found above the hook or it could not be read.
    public let arguments: [String]?
    public let entrypoint: String?

    public init(arguments: [String]?, entrypoint: String?) {
        self.arguments = arguments
        self.entrypoint = entrypoint
    }

    /// The launch of the Claude Code process that started this hook.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeLaunch {
        ClaudeLaunch(
            arguments: claudeArguments(among: ProcessInspector.ancestors()),
            entrypoint: environment[entrypointVariable]
        )
    }

    /// True when nobody is at a Claude Code prompt for this run: it was
    /// started to run without one, and no host application answers its
    /// prompts. Anything unclear is treated as attended, which is what the
    /// notch did before it could tell.
    public var isUnattended: Bool {
        if let arguments {
            let flags = Self.flags(in: arguments)
            // A host answers prompts itself: the VS Code extension, the
            // desktop app, an SDK application with its own approval screen.
            if Self.value(of: "--permission-prompt-tool", in: flags) == "stdio" { return false }
            if Self.runsWithoutAPrompt(flags) { return true }
        }
        return entrypoint == "sdk-cli"
    }

    /// Claude Code's arguments from the processes above a hook, nearest
    /// first. Claude Code starts a hook through a shell, so shells are
    /// skipped and the first other process is the one that ran it. If that
    /// is not Claude Code, nothing is assumed.
    public static func claudeArguments(among ancestors: [ProcessSnapshot]) -> [String]? {
        guard let launcher = ancestors.first(where: { !isShell($0) }),
              namesClaudeCode(launcher) else { return nil }
        return Array(launcher.arguments.dropFirst())
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]

    private static func isShell(_ process: ProcessSnapshot) -> Bool {
        let names = [process.executablePath, process.arguments.first ?? ""].map { value -> String in
            // A login shell is named with a leading dash ("-zsh").
            let name = URL(fileURLWithPath: value).lastPathComponent
            return name.hasPrefix("-") ? String(name.dropFirst()) : name
        }
        return names.contains(where: shells.contains)
    }

    /// The native program is called `claude`; an npm install runs
    /// `node …/claude-code/cli.js`.
    private static func namesClaudeCode(_ process: ProcessSnapshot) -> Bool {
        ([process.executablePath] + process.arguments.prefix(2))
            .contains { $0.lowercased().contains("claude") }
    }

    /// Everything before a bare `--`; after it comes the prompt text.
    private static func flags(in arguments: [String]) -> [String] {
        arguments.firstIndex(of: "--").map { Array(arguments[..<$0]) } ?? arguments
    }

    /// The flags with which Claude Code runs without its own interface:
    /// print mode, and the stream formats an SDK starts it with.
    private static func runsWithoutAPrompt(_ flags: [String]) -> Bool {
        flags.contains { flag in
            flag == "-p" || flag == "--print"
                || ["--output-format", "--input-format", "--sdk-url"].contains { name in
                    flag == name || flag.hasPrefix(name + "=")
                }
        }
    }

    private static func value(of name: String, in flags: [String]) -> String? {
        for (index, flag) in flags.enumerated() {
            if flag == name { return index + 1 < flags.count ? flags[index + 1] : nil }
            if flag.hasPrefix(name + "=") { return String(flag.dropFirst(name.count + 1)) }
        }
        return nil
    }
}

/// The owner's choice about runs nobody is watching.
public enum UnattendedRunPolicy {
    /// Whether a request from this run may wait in the notch. An attended
    /// run always may. An unattended one only if the owner asked for it;
    /// otherwise Claude Code decides, exactly as it does without the notch.
    public static func reachesNotch(isUnattended: Bool, ownerAsksAboutUnattendedRuns: Bool) -> Bool {
        !isUnattended || ownerAsksAboutUnattendedRuns
    }
}

/// Claude Code's permission modes under the names its own interface uses.
public enum ClaudePermissionModeName {
    /// Nil for a mode this version does not know, so the card never shows a
    /// raw identifier.
    public static func displayName(for mode: String?) -> String? {
        switch mode {
        case "default": "Manual"
        case "acceptEdits": "Accept edits"
        case "plan": "Plan"
        case "auto": "Auto"
        case "dontAsk": "Don't ask"
        case "bypassPermissions": "Bypass"
        default: nil
        }
    }
}
