import Foundation

/// The outcome of one external command. Output is decoded as UTF-8 with
/// replacement characters, because git and gh print UTF-8 and a lossy decode is
/// more useful to a status surface than failing on one odd byte.
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// A command that was killed on timeout never counts as a success, even if
    /// its exit status happened to be zero.
    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs an executable with an argument array. A protocol so git and gh callers
/// can be tested with scripted output instead of real processes.
public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) async -> CommandResult
}

/// Runs commands with `Process`, never through a shell, so arguments can never
/// be reinterpreted as shell syntax.
///
/// Both pipes are drained continuously while the child runs; waiting for exit
/// first would deadlock once the child fills a pipe buffer (64 KiB).
public struct ProcessCommandRunner: CommandRunning {
    /// Shell convention for "command not found".
    public static let executableNotFoundStatus: Int32 = 127
    /// Shell convention for "found but could not be started".
    public static let launchFailedStatus: Int32 = 126
    /// Per-stream cap so a runaway command cannot exhaust memory. Output past
    /// the cap is read and discarded so the child never blocks on a full pipe.
    public static let outputLimit = 16 * 1024 * 1024

    /// The child's environment; `nil` inherits this process's environment.
    public let environment: [String: String]?

    public init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval
    ) async -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return CommandResult(
                status: Self.executableNotFoundStatus,
                stderr: "\(executable): executable not found"
            )
        }
        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout
        )
        return await withTaskCancellationHandler {
            await execution.run()
        } onCancel: {
            execution.cancel()
        }
    }
}

/// One child process and the bookkeeping needed to finish exactly once: after
/// the child has exited and both pipes reached end of file.
///
/// `@unchecked Sendable` because every mutable field is guarded by `lock`;
/// `Process` callbacks arrive on arbitrary Foundation threads.
private final class ProcessExecution: @unchecked Sendable {
    private enum Stream { case stdout, stderr }

    /// How long to wait between SIGTERM and SIGKILL on timeout or cancellation.
    private static let killGracePeriod: TimeInterval = 1
    /// How long to keep reading after exit. A grandchild that inherited the
    /// pipe can hold it open indefinitely; we stop waiting rather than hang.
    private static let drainGracePeriod: TimeInterval = 2

    private let executable: String
    private let arguments: [String]
    private let workingDirectory: String?
    private let environment: [String: String]?
    private let timeout: TimeInterval

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitStatus: Int32?
    private var timedOut = false
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<CommandResult, Never>?

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
    }

    func run() async -> CommandResult {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            launch()
        }
    }

    func cancel() {
        let shouldTerminate = lock.withLock { () -> Bool in
            cancelled = true
            return !finished
        }
        if shouldTerminate { terminate() }
    }

    private func launch() {
        let alreadyCancelled = lock.withLock { cancelled }
        if alreadyCancelled {
            finish(with: CommandResult(status: -1, stderr: "cancelled before launch"))
            return
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        if let environment {
            process.environment = environment
        }
        // A closed stdin keeps tools like git and gh from waiting on a prompt.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, from: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, from: .stderr)
        }
        process.terminationHandler = { [weak self] process in
            self?.processExited(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stopReading()
            finish(with: CommandResult(
                status: ProcessCommandRunner.launchFailedStatus,
                stderr: "\(executable): could not launch: \(error.localizedDescription)"
            ))
            return
        }

        // Clamped so an infinite or absurd timeout cannot overflow the
        // dispatch deadline; a day is effectively "no timeout" here.
        let seconds = timeout.isNaN ? 0 : min(max(0, timeout), 86_400)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.timeoutFired()
        }
    }

    private func consume(_ data: Data, from stream: Stream) {
        lock.withLock {
            switch stream {
            case .stdout:
                if data.isEmpty {
                    stdoutClosed = true
                } else {
                    Self.append(data, to: &stdoutData)
                }
            case .stderr:
                if data.isEmpty {
                    stderrClosed = true
                } else {
                    Self.append(data, to: &stderrData)
                }
            }
        }
        if data.isEmpty {
            switch stream {
            case .stdout: stdoutPipe.fileHandleForReading.readabilityHandler = nil
            case .stderr: stderrPipe.fileHandleForReading.readabilityHandler = nil
            }
        }
        finishIfComplete()
    }

    private static func append(_ data: Data, to buffer: inout Data) {
        let room = ProcessCommandRunner.outputLimit - buffer.count
        guard room > 0 else { return }
        buffer.append(data.prefix(room))
    }

    private func processExited(status: Int32) {
        lock.withLock { exitStatus = status }
        finishIfComplete()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGracePeriod) { [weak self] in
            self?.finishAfterDrainGrace()
        }
    }

    private func timeoutFired() {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !finished, exitStatus == nil else { return false }
            timedOut = true
            return true
        }
        if shouldTerminate { terminate() }
    }

    /// SIGTERM first so well-behaved tools can clean up (git removes its lock
    /// files), then SIGKILL for anything that ignores it.
    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private func finishIfComplete() {
        let result = lock.withLock { () -> CommandResult? in
            guard !finished, let exitStatus, stdoutClosed, stderrClosed else { return nil }
            return makeResult(status: exitStatus)
        }
        if let result { finish(with: result) }
    }

    private func finishAfterDrainGrace() {
        let result = lock.withLock { () -> CommandResult? in
            guard !finished, let exitStatus else { return nil }
            return makeResult(status: exitStatus)
        }
        guard let result else { return }
        stopReading()
        finish(with: result)
    }

    /// Must be called with `lock` held.
    private func makeResult(status: Int32) -> CommandResult {
        CommandResult(
            status: status,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            timedOut: timedOut
        )
    }

    private func stopReading() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func finish(with result: CommandResult) {
        let continuation = lock.withLock { () -> CheckedContinuation<CommandResult, Never>? in
            guard !finished else { return nil }
            finished = true
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume(returning: result)
    }
}
