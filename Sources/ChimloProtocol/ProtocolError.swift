import Foundation

public enum ChimloProtocolError: Error, Equatable, LocalizedError, Sendable {
    case runtimeDescriptorUnavailable
    case invalidDescriptor(String)
    case unsupportedProtocolVersion(Int)
    case nonLoopbackHost(String)
    case secureRandomFailed(OSStatus)
    case payloadTooLarge(Int)
    case invalidFrame(String)
    case authenticationFailed
    case unexpectedMessage(String)
    case connectionFailed(String)
    case timedOut
    case serverAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .runtimeDescriptorUnavailable:
            "Claude Overhead is not running, or its runtime descriptor is unavailable."
        case let .invalidDescriptor(reason):
            "The Claude Overhead runtime descriptor is invalid: \(reason)."
        case let .unsupportedProtocolVersion(version):
            "Claude Overhead protocol version \(version) is not supported."
        case let .nonLoopbackHost(host):
            "Refusing to connect to non-loopback host \(host)."
        case let .secureRandomFailed(status):
            "Could not create a secure authentication token (status \(status))."
        case let .payloadTooLarge(size):
            "The Claude Overhead payload is too large (\(size) bytes)."
        case let .invalidFrame(reason):
            "The Claude Overhead frame is invalid: \(reason)."
        case .authenticationFailed:
            "Claude Overhead authentication failed."
        case let .unexpectedMessage(message):
            "Claude Overhead returned an unexpected message: \(message)."
        case let .connectionFailed(message):
            "Could not communicate with Claude Overhead: \(message)."
        case .timedOut:
            "Communication with Claude Overhead timed out."
        case .serverAlreadyRunning:
            "The Claude Overhead protocol server is already running."
        }
    }
}
