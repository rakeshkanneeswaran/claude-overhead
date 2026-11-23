import ChimloCore
import ChimloProtocol
import Foundation

enum LocalServerState: Equatable, Sendable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(message: String)
}

/// The sole translation seam between the authenticated loopback server and the
/// app model. SwiftUI never owns sockets, descriptors, or authentication state.
@MainActor
final class ProtocolBridge {
    private(set) var state: LocalServerState = .stopped

    private var server: ChimloServer?
    private var startupTask: Task<Void, Never>?

    func start(
        receive: @escaping @MainActor @Sendable (AgentEvent) -> Void,
        decide: @escaping @MainActor @Sendable (ChimloDecisionRequest) async -> ChimloDecisionResponse,
        permit: @escaping @MainActor @Sendable (ProviderPermissionRequest) async -> ProviderPermissionResponse,
        answer: @escaping @MainActor @Sendable (ProviderQuestionRequest) async -> ProviderQuestionResponse,
        stateChanged: @escaping @MainActor @Sendable (LocalServerState) -> Void
    ) {
        stop()
        setState(.starting, notify: stateChanged)

        startupTask = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                // A listener that was ready can still fail later; the server
                // reports it here and the loop below starts a new one.
                let (listenerFailures, reportListenerFailure) = AsyncStream<String>.makeStream()
                do {
                    let server = try ChimloServer(
                        eventHandler: { event in
                            await receive(event)
                        },
                        decisionHandler: { request in
                            await decide(request)
                        },
                        permissionHandler: { request in
                            await permit(request)
                        },
                        questionHandler: { request in
                            await answer(request)
                        },
                        listenerFailureHandler: { reason in
                            reportListenerFailure.yield(reason)
                        }
                    )
                    self.server = server
                    let descriptor = try await server.start()

                    guard !Task.isCancelled else {
                        server.stop()
                        return
                    }
                    self.setState(.listening(port: descriptor.port), notify: stateChanged)
                    failures = 0

                    // Listening. Wait here until the listener fails (the
                    // server has removed its descriptor by then) or stop()
                    // cancels this task, which ends the stream with nil.
                    var listenerFailure = listenerFailures.makeAsyncIterator()
                    guard let reason = await listenerFailure.next(), !Task.isCancelled else { return }
                    throw ChimloProtocolError.connectionFailed(reason)
                } catch is CancellationError {
                    self.server?.stop()
                    self.server = nil
                    self.setState(.stopped, notify: stateChanged)
                    return
                } catch {
                    self.server?.stop()
                    self.server = nil
                    self.setState(.failed(message: Self.conciseMessage(for: error)), notify: stateChanged)
                    // Meanwhile hooks fall back to Claude Code's own prompts.
                    // Keep trying, so recovering never needs a restart.
                    failures += 1
                    try? await Task.sleep(for: ServerRestartPolicy.delay(afterFailures: failures))
                    guard !Task.isCancelled else { return }
                    self.setState(.starting, notify: stateChanged)
                }
            }
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        server?.stop()
        server = nil
        state = .stopped
    }

    private func setState(
        _ state: LocalServerState,
        notify: @MainActor @Sendable (LocalServerState) -> Void
    ) {
        self.state = state
        notify(state)
    }

    private static func conciseMessage(for error: Error) -> String {
        let description = String(describing: error)
        return description.isEmpty ? "Local listener unavailable" : description
    }
}
