import Foundation

public enum ClaudeStatusLineConfigurationError: Error, LocalizedError, Sendable {
    case malformedRoot
    case malformedStatusLine

    public var errorDescription: String? {
        switch self {
        case .malformedRoot:
            "Claude settings must be a JSON object"
        case .malformedStatusLine:
            "Claude's existing statusLine setting must be a command object"
        }
    }
}

public enum ClaudeStatusLineInstallationState: Equatable, Sendable {
    case missing
    case current
    case needsRepair
}

public struct ClaudeStatusLineConfigurationPlan: Equatable, Sendable {
    public let data: Data
    public let changed: Bool

    public init(data: Data, changed: Bool) {
        self.data = data
        self.changed = changed
    }
}

/// Marker-scoped configuration for Claude Overhead's capacity-only Claude status-line
/// bridge. The original status-line object is retained verbatim at the JSON
/// value level and restored on removal.
public enum ClaudeStatusLineConfiguration {
    public static let managedKey = "_overheadStatusLineManaged"
    public static let originalKey = "_overheadOriginalStatusLine"
    public static let refreshIntervalSeconds = 60

    /// The `statusLine.command` written to Claude's settings. Claude Code runs
    /// the command through a shell, and the wrapper lives under "Application
    /// Support": unquoted, the shell splits the path at the space and nothing
    /// runs, which also blanks the status line the wrapper is meant to pass
    /// through. Through 1.0.6 the bare path was written.
    public static func command(wrapperPath: String) -> String {
        "'\(wrapperPath.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Whether a `statusLine.command` is Claude Overhead's own: the quoted
    /// command, or the bare path earlier versions wrote. The bare path must
    /// count, or repairing it would save it as the owner's "original".
    public static func isManagedCommand(_ command: String?, wrapperPath: String) -> Bool {
        guard let command else { return false }
        return command == Self.command(wrapperPath: wrapperPath) || command == wrapperPath
    }

    public static func installationState(
        in data: Data?,
        wrapperPath: String
    ) throws -> ClaudeStatusLineInstallationState {
        guard let data, !data.isEmpty else { return .missing }
        let root = try decodeRoot(data)
        guard root[managedKey] as? Bool == true else { return .missing }
        guard let statusLine = root["statusLine"] as? [String: Any],
              statusLine["type"] as? String == "command",
              statusLine["command"] as? String == command(wrapperPath: wrapperPath),
              (statusLine["refreshInterval"] as? NSNumber)?.intValue
                == refreshIntervalSeconds else {
            return .needsRepair
        }
        return .current
    }

    public static func merging(
        existingData: Data?,
        wrapperPath: String
    ) throws -> ClaudeStatusLineConfigurationPlan {
        let existingRoot = try existingData.flatMap { $0.isEmpty ? nil : try decodeRoot($0) }
        var root = existingRoot ?? [:]
        let wasManaged = root[managedKey] as? Bool == true

        if let existingStatusLine = root["statusLine"] {
            guard let object = existingStatusLine as? [String: Any],
                  object["type"] as? String == "command",
                  object["command"] is String else {
                throw ClaudeStatusLineConfigurationError.malformedStatusLine
            }
            let existingCommand = object["command"] as? String
            let isOurs = isManagedCommand(existingCommand, wrapperPath: wrapperPath)
            if !isOurs {
                root[originalKey] = object
            } else if !wasManaged {
                // Our wrapper without our bookkeeping: there is no original
                // to keep, and the wrapper must never become its own delegate.
                root.removeValue(forKey: originalKey)
            }
        } else if wasManaged {
            // If another tool deliberately removed Claude Overhead's wrapper, do not
            // resurrect the status line that predated that external change.
            root.removeValue(forKey: originalKey)
        }

        // The saved original must never be our own wrapper: its delegate
        // script would run the wrapper, which runs the delegate, without end.
        // 1.0.6 and earlier save it that way when they "repair" the quoted
        // command a newer version wrote.
        if let original = root[originalKey] as? [String: Any],
           isManagedCommand(original["command"] as? String, wrapperPath: wrapperPath) {
            root.removeValue(forKey: originalKey)
        }

        var managed = (root[originalKey] as? [String: Any]) ?? [:]
        managed["type"] = "command"
        managed["command"] = command(wrapperPath: wrapperPath)
        managed["refreshInterval"] = refreshIntervalSeconds
        root["statusLine"] = managed
        root[managedKey] = true

        // Compared as values, not bytes: Claude Code rewrites this file in
        // its own formatting, and a byte comparison would then have every
        // launch rewrite the owner's settings for nothing.
        if let existingData, let existingRoot,
           NSDictionary(dictionary: root).isEqual(to: existingRoot) {
            return ClaudeStatusLineConfigurationPlan(data: existingData, changed: false)
        }
        return ClaudeStatusLineConfigurationPlan(data: try encode(root), changed: true)
    }

    /// Produces the capacity-bridge migration only when Claude's Claude Overhead hooks
    /// are already connected. This lets existing users receive new bridge
    /// capabilities without treating an unrelated Claude installation as
    /// connected or taking ownership of its status line.
    public static func upgradingConnectedInstallation(
        existingData: Data?,
        helperPath: String,
        wrapperPath: String
    ) throws -> ClaudeStatusLineConfigurationPlan? {
        guard let existingData, !existingData.isEmpty,
              try ClaudeHookConfiguration.installationState(
                in: existingData,
                helperPath: helperPath
              ) == .current else {
            return nil
        }
        return try merging(existingData: existingData, wrapperPath: wrapperPath)
    }

    public static func removing(
        existingData: Data,
        wrapperPath: String
    ) throws -> ClaudeStatusLineConfigurationPlan {
        var root = try decodeRoot(existingData)
        guard root[managedKey] as? Bool == true else {
            return ClaudeStatusLineConfigurationPlan(data: existingData, changed: false)
        }

        // Only our own wrapper is taken out. A status line the owner set
        // after connecting (or removed on purpose) is theirs: it stays
        // exactly as it is, and only the bookkeeping goes.
        let current = root["statusLine"] as? [String: Any]
        if isManagedCommand(current?["command"] as? String, wrapperPath: wrapperPath) {
            if let original = root[originalKey] as? [String: Any],
               !isManagedCommand(original["command"] as? String, wrapperPath: wrapperPath) {
                root["statusLine"] = original
            } else {
                // Nothing to give back (or only our own wrapper, saved by an
                // older version's repair): the status line simply goes.
                root.removeValue(forKey: "statusLine")
            }
        }
        root.removeValue(forKey: originalKey)
        root.removeValue(forKey: managedKey)
        return ClaudeStatusLineConfigurationPlan(data: try encode(root), changed: true)
    }

    public static func originalCommand(in data: Data) throws -> String? {
        let root = try decodeRoot(data)
        guard root[managedKey] as? Bool == true,
              let original = root[originalKey] as? [String: Any] else {
            return nil
        }
        return original["command"] as? String
    }

    private static func decodeRoot(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStatusLineConfigurationError.malformedRoot
        }
        return object
    }

    private static func encode(_ root: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(root) else {
            throw ClaudeStatusLineConfigurationError.malformedRoot
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
    }
}
