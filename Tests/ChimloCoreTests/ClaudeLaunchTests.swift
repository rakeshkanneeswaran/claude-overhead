import Darwin
import Foundation
import Testing
@testable import ChimloCore

/// Claude Code runs the PermissionRequest hook both when it is about to
/// prompt a person and when nobody can be prompted. Through 1.0.7 the notch
/// could not tell them apart, so a script's `claude -p` runs each stopped
/// for up to ten minutes behind a card nobody was expecting.
@Suite("Claude launch: attended or not")
struct ClaudeLaunchTests {
    private static func unattended(_ arguments: [String]?, entrypoint: String? = nil) -> Bool {
        ClaudeLaunch(arguments: arguments, entrypoint: entrypoint).isUnattended
    }

    /// The command line the VS Code extension starts Claude Code with.
    private static let vsCodeArguments = [
        "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
        "--max-thinking-tokens=31999", "--permission-prompt-tool=stdio",
        "--resume=11111111-2222-4333-8444-555555555555", "--setting-sources=user,project,local",
        "--include-partial-messages",
    ]

    @Test("Print mode has nobody at a prompt")
    func printMode() {
        #expect(Self.unattended(["-p", "fix the tests"]))
        #expect(Self.unattended(["--print", "fix the tests"]))
        #expect(Self.unattended(["--model", "opus", "--effort", "low", "-p", "run the experiment"]))
        #expect(Self.unattended(["-p", "--output-format", "json", "summarise"]))
    }

    @Test("An interactive session is attended")
    func interactive() {
        #expect(!Self.unattended([]))
        #expect(!Self.unattended(["--resume", "abc"]))
        #expect(!Self.unattended(["--permission-mode", "auto"]))
        #expect(!Self.unattended(["fix the tests"]))
        // After a bare "--" comes the prompt, whatever it looks like.
        #expect(!Self.unattended(["--", "-p"]))
        #expect(!Self.unattended(["--model", "opus", "--", "--print", "this"]))
    }

    @Test("A host that answers prompts makes the session attended")
    func hostAnswersPrompts() {
        #expect(!Self.unattended(Self.vsCodeArguments))
        #expect(!Self.unattended(["-p", "--permission-prompt-tool", "stdio", "--input-format", "stream-json"]))
        // The entry point is inherited and says nothing against a host.
        #expect(!Self.unattended(Self.vsCodeArguments, entrypoint: "sdk-cli"))
        #expect(!Self.unattended(["", "", ""], entrypoint: "claude-vscode"))
    }

    @Test("An SDK run with no host, or with a tool that answers, is unattended")
    func sdkWithoutAHost() {
        #expect(Self.unattended(["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]))
        #expect(Self.unattended(["--output-format=stream-json", "--input-format=stream-json"]))
        #expect(Self.unattended(["--sdk-url", "wss://example.invalid/session"]))
        // A tool decides, not a person at Claude Code's prompt.
        #expect(Self.unattended(["-p", "--permission-prompt-tool", "mcp__approvals__ask", "go"]))
        #expect(Self.unattended(["-p", "--permission-prompt-tool=mcp__approvals__ask", "go"]))
    }

    @Test("A run started from inside a VS Code session keeps that session's entry point")
    func inheritedEntrypoint() {
        // The case that showed the bug: the arguments decide, not the
        // inherited variable.
        #expect(Self.unattended(["-p", "run 02"], entrypoint: "claude-vscode"))
        #expect(Self.unattended(["-p", "run 02"], entrypoint: "cli"))
    }

    @Test("Arguments that were read decide, whatever variable the session inherited")
    func readableArgumentsDecide() {
        // An interactive session opened from inside a `claude -p` run (a
        // tmux pane, say) inherits sdk-cli. It has a person at it.
        #expect(!Self.unattended([], entrypoint: "sdk-cli"))
        #expect(!Self.unattended(["--resume", "abc"], entrypoint: "sdk-cli"))
        #expect(!Self.unattended(["fix the tests"], entrypoint: "sdk-cli"))
        // And a print run is unattended whatever it inherited.
        #expect(Self.unattended(["-p", "go"], entrypoint: "cli"))
    }

    @Test("Hidden arguments tell nothing, so the entry point decides")
    func hiddenArguments() {
        // An npm install renames its process, which blanks its arguments:
        // they are still counted, but each reads as empty.
        #expect(ClaudeLaunch.areHidden(["", ""]))
        #expect(ClaudeLaunch.areHidden([""]))
        #expect(!ClaudeLaunch.areHidden([]))
        #expect(!ClaudeLaunch.areHidden(["", "-p"]))
        #expect(Self.unattended(["", "", ""], entrypoint: "sdk-cli"))
        #expect(!Self.unattended(["", "", ""], entrypoint: "cli"))
        #expect(!Self.unattended(["", ""], entrypoint: nil))
    }

    @Test("Without readable arguments the entry point decides, and only sdk-cli is unattended")
    func entrypointFallback() {
        #expect(Self.unattended(nil, entrypoint: "sdk-cli"))
        for entrypoint in ["cli", "claude-vscode", "claude-desktop", "sdk-ts", "sdk-py", "something-new", ""] {
            #expect(!Self.unattended(nil, entrypoint: entrypoint), "\(entrypoint)")
        }
        #expect(!Self.unattended(nil, entrypoint: nil))
    }

    // MARK: Finding Claude Code above the hook

    private static func process(_ id: Int32, _ path: String, _ arguments: [String]) -> ProcessSnapshot {
        ProcessSnapshot(processID: id, parentProcessID: id - 1, executablePath: path, arguments: arguments)
    }

    private static let nativeClaude = "/opt/homebrew/Caskroom/claude-code/2.1.280/claude"

    @Test("The nearest Claude Code process is the one that ran the hook")
    func nearestClaude() {
        // helper <- sh <- `claude -p` <- python harness <- zsh <- VS Code's Claude Code
        let ancestors = [
            Self.process(50, "/bin/sh", ["/bin/sh", "-c", "'/path/overhead' hook claude permission"]),
            Self.process(49, Self.nativeClaude, ["claude", "--model", "opus", "-p", "run 02"]),
            Self.process(48, "/usr/bin/python3", ["python3", "harness.py"]),
            Self.process(47, "/bin/zsh", ["/bin/zsh", "-c", "python3 harness.py"]),
            Self.process(46, "/x/native-binary/claude", ["/x/native-binary/claude"] + Self.vsCodeArguments),
        ]
        let arguments = ClaudeLaunch.claudeArguments(among: ancestors)
        #expect(arguments == ["--model", "opus", "-p", "run 02"])
        #expect(ClaudeLaunch(arguments: arguments, entrypoint: "claude-vscode").isUnattended)
    }

    @Test("The VS Code session itself is found and is attended")
    func vsCodeSession() {
        let ancestors = [
            Self.process(50, "/bin/zsh", ["-zsh"]),
            Self.process(49, "/x/native-binary/claude", ["/x/native-binary/claude"] + Self.vsCodeArguments),
        ]
        let arguments = ClaudeLaunch.claudeArguments(among: ancestors)
        #expect(arguments == Self.vsCodeArguments)
        #expect(!ClaudeLaunch(arguments: arguments, entrypoint: "claude-vscode").isUnattended)
    }

    @Test("An npm install is recognised by its script path")
    func npmInstall() {
        let ancestors = [
            Self.process(49, "/usr/local/bin/node", [
                "node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "-p", "go",
            ]),
        ]
        let arguments = ClaudeLaunch.claudeArguments(among: ancestors)
        #expect(arguments?.suffix(2) == ["-p", "go"])
        #expect(ClaudeLaunch(arguments: arguments, entrypoint: nil).isUnattended)
    }

    @Test("A launcher that is not Claude Code tells nothing")
    func unknownLauncher() {
        let ancestors = [
            Self.process(50, "/bin/bash", ["bash", "-c", "overhead hook claude permission"]),
            Self.process(49, "/usr/bin/make", ["make", "-p", "check"]),
            Self.process(48, Self.nativeClaude, ["claude", "-p", "go"]),
        ]
        #expect(ClaudeLaunch.claudeArguments(among: ancestors) == nil)
        #expect(ClaudeLaunch.claudeArguments(among: []) == nil)
        #expect(ClaudeLaunch.claudeArguments(among: [Self.process(50, "/bin/sh", ["sh"])]) == nil)
    }

    // MARK: Reading processes

    @Test("This process's arguments and parent are read from the system")
    func readsThisProcess() throws {
        let snapshot = try #require(ProcessInspector.snapshot(of: getpid()))
        #expect(snapshot.processID == getpid())
        #expect(snapshot.parentProcessID == getppid())
        #expect(snapshot.arguments == CommandLine.arguments)
        #expect(!snapshot.executablePath.isEmpty)
    }

    @Test("Ancestors come nearest first and stop at the limit")
    func ancestors() throws {
        let all = ProcessInspector.ancestors()
        let first = try #require(all.first)
        #expect(first.processID == getppid())
        #expect(all.count <= 8)
        #expect(Set(all.map(\.processID)).count == all.count)
        #expect(ProcessInspector.ancestors(limit: 1).count == 1)
        #expect(ProcessInspector.ancestors(limit: 0).isEmpty)
    }

    @Test("A process that does not exist is unreadable, not a crash")
    func missingProcess() {
        #expect(ProcessInspector.snapshot(of: 0) == nil)
        #expect(ProcessInspector.snapshot(of: -5) == nil)
        #expect(ProcessInspector.snapshot(of: Int32.max - 7) == nil)
        #expect(ProcessInspector.ancestors(of: Int32.max - 7).isEmpty)
    }

    private static func block(count: Int32, _ pieces: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: count) { Array($0) } + pieces
    }

    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test("The argument block is parsed and its environment is left alone")
    func parsesArgumentBlock() throws {
        let block = Self.block(
            count: 3,
            Self.bytes("/bin/claude") + [0, 0, 0, 0]
                + Self.bytes("claude") + [0] + Self.bytes("-p") + [0] + Self.bytes("go now") + [0]
                + Self.bytes("SECRET_TOKEN=abc") + [0]
        )
        let parsed = try #require(ProcessInspector.parse(argumentBlock: block))
        #expect(parsed.executablePath == "/bin/claude")
        #expect(parsed.arguments == ["claude", "-p", "go now"])
    }

    @Test("A damaged argument block is rejected or read only as far as it goes")
    func damagedArgumentBlock() {
        #expect(ProcessInspector.parse(argumentBlock: []) == nil)
        #expect(ProcessInspector.parse(argumentBlock: [1, 0, 0]) == nil)
        #expect(ProcessInspector.parse(argumentBlock: Self.block(count: 0, Self.bytes("/bin/x") + [0])) == nil)
        #expect(ProcessInspector.parse(argumentBlock: Self.block(count: -3, Self.bytes("/bin/x") + [0, 0])) == nil)
        // No terminator after the path.
        #expect(ProcessInspector.parse(argumentBlock: Self.block(count: 2, Self.bytes("/bin/x"))) == nil)
        // A path and nothing after it.
        #expect(ProcessInspector.parse(argumentBlock: Self.block(count: 2, Self.bytes("/bin/x") + [0, 0])) == nil)
        // The count promises more than the block holds.
        let short = Self.block(count: Int32.max, Self.bytes("/bin/x") + [0] + Self.bytes("x") + [0] + Self.bytes("-p"))
        #expect(ProcessInspector.parse(argumentBlock: short)?.arguments == ["x", "-p"])
    }

    @Test("The launch of the process running these tests is attended")
    func currentLaunch() {
        // Whatever runs the tests, a missing or foreign launcher must never
        // read as an unattended run.
        let launch = ClaudeLaunch.current(environment: [:])
        #expect(launch.entrypoint == nil)
        if launch.arguments == nil { #expect(!launch.isUnattended) }
        #expect(ClaudeLaunch.current(environment: [ClaudeLaunch.entrypointVariable: "cli"]).entrypoint == "cli")
    }
}
