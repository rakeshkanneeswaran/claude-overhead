import Foundation

/// One entry of `claude agents --json`: Claude Code's own, supported list of
/// the live sessions on this Mac, interactive and background. It is the only
/// documented way to see background sessions, and its pid makes host lookup
/// exact. Cloud sessions are not in it; Claude Code offers no local listing
/// for those.
public struct ClaudeLiveSession: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case interactive
        case background
        case unknown
    }

    public var id: String { sessionID }
    public let sessionID: String
    public let pid: Int32?
    public let cwd: String?
    public let kind: Kind
    public let startedAt: Date?
    public let name: String?
    /// As Claude Code reports it, for example "busy" or "idle".
    public let status: String?

    public init(sessionID: String, pid: Int32?, cwd: String?, kind: Kind, startedAt: Date?, name: String?, status: String?) {
        self.sessionID = sessionID
        self.pid = pid
        self.cwd = cwd
        self.kind = kind
        self.startedAt = startedAt
        self.name = name
        self.status = status
    }

    public var isBusy: Bool { status?.lowercased() == "busy" }
}

public enum ClaudeAgentsListing {
    /// Decodes the listing leniently: entries without a session id are
    /// skipped, unknown kinds and extra fields are tolerated, so a newer
    /// Claude Code never makes the whole list disappear.
    public static func parse(_ data: Data) -> [ClaudeLiveSession] {
        // Cast per entry: one malformed element must not hide every session.
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return entries.compactMap { element in
            guard let entry = element as? [String: Any],
                  let sessionID = entry["sessionId"] as? String, !sessionID.isEmpty else { return nil }
            let startedAt = (entry["startedAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1_000)
            }
            return ClaudeLiveSession(
                sessionID: sessionID,
                pid: (entry["pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.intValue) },
                cwd: entry["cwd"] as? String,
                kind: (entry["kind"] as? String).flatMap(ClaudeLiveSession.Kind.init(rawValue:)) ?? .unknown,
                startedAt: startedAt,
                name: entry["name"] as? String,
                status: entry["status"] as? String
            )
        }
    }
}
