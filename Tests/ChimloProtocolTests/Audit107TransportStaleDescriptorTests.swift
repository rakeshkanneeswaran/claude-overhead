import Darwin
import Foundation
import Network
import Testing
import ChimloCore
@testable import ChimloProtocol

/// An app that crashed or was killed leaves its descriptor behind. A hook
/// that finds one must hand back to Claude Code's own prompt at once: it may
/// not wait out its ten-minute timeout, and it may not talk to whatever
/// holds the old port.
@Suite("Audit 107: stale runtime descriptor", .serialized)
struct Audit107TransportStaleDescriptorTests {
    /// Above the largest process identifier macOS hands out, so never alive.
    private static let deadProcessID: Int32 = 2_000_000_000
    private static let token = String(repeating: "a", count: 64)

    @Test("Only a process that no longer exists counts as gone")
    func ownerLiveness() {
        let own = RuntimeDescriptor(port: 1, authenticationToken: Self.token)
        #expect(own.isOwnerAlive)

        // launchd exists but may not be signalled: "not permitted" is alive.
        let launchd = RuntimeDescriptor(port: 1, authenticationToken: Self.token, processID: 1)
        #expect(launchd.isOwnerAlive)

        let gone = RuntimeDescriptor(port: 1, authenticationToken: Self.token, processID: Self.deadProcessID)
        #expect(!gone.isOwnerAlive)
    }

    @Test("The descriptor a running server writes names a live process and still works")
    func liveDescriptorStillWorks() async throws {
        let (store, directory) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try ChimloServer(descriptorStore: store, eventHandler: { _ in })
        defer { server.stop() }
        let descriptor = try await server.start()

        #expect(descriptor.isOwnerAlive)
        try await ChimloClient(descriptorStore: store, timeout: Patience.expected).ping()
    }

    @Test("A descriptor whose app is gone is never used, even if something answers on its port", .timeLimit(.minutes(3)))
    func deadOwnerIsNeverContacted() async throws {
        let (store, directory) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let received = EventCounter()
        // Stands in for whatever took over the dead app's port: it would
        // accept the token and approve everything.
        let server = try ChimloServer(
            descriptorStore: store,
            eventHandler: { _ in await received.increment() },
            permissionHandler: { request in
                await received.increment()
                return ProviderPermissionResponse(requestID: request.id, outcome: .allowedOnce)
            },
            questionHandler: { request in
                await received.increment()
                return ProviderQuestionResponse(
                    requestID: request.id, outcome: .answered, answers: ["Ship it?": "Yes"]
                )
            }
        )
        defer { server.stop() }
        let live = try await server.start()
        try store.write(RuntimeDescriptor(
            port: live.port,
            authenticationToken: live.authenticationToken,
            processID: Self.deadProcessID
        ))
        // Waiting out the timeout would take five minutes; failing at once
        // is over long before that on any machine.
        let client = try ChimloClient(descriptorStore: store, timeout: Patience.leftAlone)

        let started = ContinuousClock.now
        let permission = await client.requestPermission(Self.permissionRequest)
        let question = await client.requestQuestion(Self.questionRequest)
        await #expect(throws: ChimloProtocolError.runtimeDescriptorUnavailable) {
            _ = try await client.ping()
        }
        await #expect(throws: ChimloProtocolError.runtimeDescriptorUnavailable) {
            _ = try await client.sendEvent(AgentEvent(sessionID: "s", sequence: 0, kind: .activity, agent: .claude))
        }

        #expect(permission.outcome == .unavailable)
        #expect(!permission.outcome.grantsPermission)
        #expect(question.outcome == .unavailable)
        #expect(question.answers.isEmpty)
        #expect(ContinuousClock.now - started < Patience.expected)
        #expect(await received.value == 0)
    }

    @Test("A port nobody listens on fails at once instead of waiting for the timeout", .timeLimit(.minutes(3)))
    func refusedConnectionFailsFast() async throws {
        let (store, directory) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The owner is alive (this process), so only the refused connection
        // can end the exchange. The timeout is far longer than the test allows.
        try store.write(RuntimeDescriptor(port: try Self.closedPort(), authenticationToken: Self.token))
        let client = try ChimloClient(descriptorStore: store, timeout: Patience.leftAlone)

        let started = ContinuousClock.now
        let permission = await client.requestPermission(Self.permissionRequest)
        let question = await client.requestQuestion(Self.questionRequest)
        let decision = await client.requestDecision(ChimloDecisionRequest(title: "Run?", message: "No listener"))
        await #expect(throws: ChimloProtocolError.self) { _ = try await client.ping() }
        let elapsed = ContinuousClock.now - started

        #expect(permission.outcome == .unavailable)
        #expect(!permission.outcome.grantsPermission)
        #expect(question.outcome == .unavailable)
        #expect(question.answers.isEmpty)
        #expect(decision.outcome == .unavailable)
        #expect(elapsed < Patience.expected, "four refused exchanges took \(elapsed)")
    }

    // MARK: Fixtures

    private static let permissionRequest = ProviderPermissionRequest(
        sessionID: "claude-1", agent: .claude, title: "overhead",
        toolName: "Bash", prompt: "Run this command?", allowsSessionApproval: true
    )

    private static let questionRequest = ProviderQuestionRequest(
        sessionID: "claude-1", agent: .claude, title: "overhead",
        questions: [ProviderQuestion(
            prompt: "Ship it?",
            options: [ProviderQuestionOption(label: "Yes"), ProviderQuestionOption(label: "No")]
        )]
    )

    private static func temporaryStore() -> (RuntimeDescriptorStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-audit107-tests-\(UUID().uuidString)", isDirectory: true)
        return (RuntimeDescriptorStore(descriptorURL: directory.appendingPathComponent("runtime.json")), directory)
    }

    /// A loopback port that was just free: bound to learn its number, then
    /// closed without ever listening, so a connection to it is refused.
    private static func closedPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound, address.sin_port != 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// A listener that was ready and then stops must be reported, so the app
/// removes its descriptor and starts a new one instead of showing
/// "listening" over a dead port.
@Suite("Audit 107: listener failure after ready", .serialized)
struct Audit107TransportListenerFailureTests {
    @Test("Only failed and waiting are failures of a listener that was ready")
    func failureStates() {
        #expect(ChimloServer.failureAfterReady(.failed(.posix(.ECONNABORTED))) != nil)
        #expect(ChimloServer.failureAfterReady(.waiting(.posix(.ENETDOWN))) != nil)
        #expect(ChimloServer.failureAfterReady(.ready) == nil)
        #expect(ChimloServer.failureAfterReady(.setup) == nil)
        // The server's own stop() cancels the listener: not a failure.
        #expect(ChimloServer.failureAfterReady(.cancelled) == nil)
    }

    @Test("A listener that fails after it was ready removes its descriptor, reports once, and can be replaced", .timeLimit(.minutes(3)))
    func failureAfterReadyIsReported() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-audit107-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeDescriptorStore(descriptorURL: directory.appendingPathComponent("runtime.json"))
        let failures = FailureLog()
        let server = try ChimloServer(
            descriptorStore: store,
            eventHandler: { _ in },
            permissionHandler: { request in
                ProviderPermissionResponse(requestID: request.id, outcome: .allowedOnce)
            },
            listenerFailureHandler: { reason in failures.record(reason) }
        )
        defer { server.stop() }
        _ = try await server.start()
        let client = try ChimloClient(descriptorStore: store, timeout: Patience.leftAlone)
        try await client.ping()

        // States that are not failures change nothing.
        server.deliverListenerState(.ready)
        #expect(failures.reasons.isEmpty)
        try await client.ping()

        server.deliverListenerState(.failed(.posix(.ECONNABORTED)))

        #expect(failures.reasons.count == 1)
        #expect(failures.reasons.first?.contains("Listener failed") == true)
        #expect(!FileManager.default.fileExists(atPath: store.descriptorURL.path))
        // With the descriptor gone a hook falls back at once and grants nothing.
        let started = ContinuousClock.now
        let request = ProviderPermissionRequest(
            sessionID: "claude-1", agent: .claude, title: "overhead",
            toolName: "Bash", prompt: "Run this command?", allowsSessionApproval: true
        )
        let response = await client.requestPermission(request)
        #expect(response.outcome == .unavailable)
        #expect(ContinuousClock.now - started < Patience.expected)

        // The owner's retry: the same server starts again and answers.
        _ = try await server.start()
        try await client.ping()
        #expect(failures.reasons.count == 1)
    }

    @Test("Stopping a server is not reported as a listener failure, and removes its descriptor")
    func stopIsNotAFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-audit107-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeDescriptorStore(descriptorURL: directory.appendingPathComponent("runtime.json"))
        let failures = EventCounter()
        let server = try ChimloServer(
            descriptorStore: store,
            eventHandler: { _ in },
            listenerFailureHandler: { _ in Task { await failures.increment() } }
        )
        _ = try await server.start()
        try await ChimloClient(descriptorStore: store, timeout: Patience.expected).ping()

        server.stop()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(await failures.value == 0)
        #expect(!FileManager.default.fileExists(atPath: store.descriptorURL.path))
        // The server can be started again after a stop, as the retry loop does.
        _ = try await server.start()
        try await ChimloClient(descriptorStore: store, timeout: Patience.expected).ping()
        server.stop()
    }
}

/// Reasons handed to a listener failure handler, which is not async.
private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var reasons: [String] { lock.withLock { recorded } }

    func record(_ reason: String) {
        lock.withLock { recorded.append(reason) }
    }
}

private actor EventCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}
