import Foundation
import Testing
@testable import ChimloCore

@Suite("Process command runner")
struct GitCommandRunnerTests {
    private let runner = ProcessCommandRunner()

    @Test("Captures stdout and a zero exit status")
    func capturesStdout() async {
        let result = await runner.run("/bin/echo", ["hello", "world"], workingDirectory: nil, timeout: Patience.expectedSeconds)
        #expect(result.status == 0)
        #expect(result.succeeded)
        #expect(result.stdout == "hello world\n")
        #expect(result.stderr.isEmpty)
        #expect(!result.timedOut)
    }

    @Test("Arguments are passed literally, never through a shell")
    func argumentsAreLiteral() async {
        let result = await runner.run("/bin/echo", ["$HOME; echo injected"], workingDirectory: nil, timeout: Patience.expectedSeconds)
        #expect(result.stdout == "$HOME; echo injected\n")
    }

    @Test("Captures stderr and a failing exit status")
    func capturesStderr() async {
        let result = await runner.run("/bin/ls", ["/definitely/not/a/real/path"], workingDirectory: nil, timeout: Patience.expectedSeconds)
        #expect(result.status != 0)
        #expect(!result.succeeded)
        #expect(!result.stderr.isEmpty)
    }

    @Test("A missing executable reports status 127 without launching")
    func missingExecutable() async {
        let result = await runner.run("/nonexistent/overhead-tool", [], workingDirectory: nil, timeout: Patience.expectedSeconds)
        #expect(result.status == 127)
        #expect(result.stderr.contains("not found"))
        #expect(!result.succeeded)
    }

    // The time limit only stops a command that was never killed from holding
    // the run for the five minutes it sleeps.
    @Test("A command past its timeout is killed and flagged", .timeLimit(.minutes(3)))
    func timeoutKills() async {
        let start = ContinuousClock.now
        // Left alone, the command would run for five minutes. Killed, it is
        // over long before that, however slowly this machine gets to it.
        let result = await runner.run(
            "/bin/sleep", ["\(Int(Patience.leftAloneSeconds))"], workingDirectory: nil, timeout: 0.3
        )
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(ContinuousClock.now - start < Patience.expected)
    }

    @Test("Large output is drained without deadlocking on a full pipe")
    func largeOutput() async {
        let result = await runner.run("/usr/bin/seq", ["1", "200000"], workingDirectory: nil, timeout: Patience.expectedSeconds)
        let lines = result.stdout.split(separator: "\n")
        #expect(result.succeeded)
        #expect(lines.count == 200_000)
        #expect(lines.last == "200000")
    }

    @Test("Stdin is closed so a reader exits instead of waiting")
    func stdinClosed() async {
        let result = await runner.run("/bin/cat", [], workingDirectory: nil, timeout: Patience.expectedSeconds)
        #expect(result.succeeded)
        #expect(result.stdout.isEmpty)
        #expect(!result.timedOut)
    }

    @Test("Runs in the requested working directory")
    func workingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await runner.run("/bin/pwd", ["-P"], workingDirectory: directory.path, timeout: Patience.expectedSeconds)
        let reported = result.stdout.trimmingCharacters(in: .newlines)
        #expect(reported == canonicalPath(directory.path))
    }

    @Test("An explicit environment replaces the inherited one")
    func explicitEnvironment() async {
        let isolated = ProcessCommandRunner(environment: ["OVERHEAD_TEST_VALUE": "42"])
        let result = await isolated.run("/usr/bin/env", [], workingDirectory: nil, timeout: Patience.expectedSeconds)
        #expect(result.stdout == "OVERHEAD_TEST_VALUE=42\n")
    }

    @Test("Cancelling the calling task stops the child process", .timeLimit(.minutes(3)))
    func cancellation() async {
        let start = ContinuousClock.now
        let task = Task {
            // Neither the command nor its timeout would end this for five minutes.
            await ProcessCommandRunner().run(
                "/bin/sleep", ["\(Int(Patience.leftAloneSeconds))"],
                workingDirectory: nil, timeout: Patience.leftAloneSeconds * 2
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.value
        #expect(!result.succeeded)
        #expect(ContinuousClock.now - start < Patience.expected)
    }
}

/// Resolves symlinks such as /var -> /private/var, which git and `pwd -P`
/// report but temporary-directory APIs do not.
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
