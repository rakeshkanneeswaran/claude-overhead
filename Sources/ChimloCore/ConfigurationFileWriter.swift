import Foundation

/// Replaces a settings file Claude Overhead shares with its owner and with
/// Claude Code, without stepping on either.
public enum ConfigurationFileWriter {
    public enum WriteError: Error, LocalizedError, Equatable, Sendable {
        case changedMeanwhile

        public var errorDescription: String? {
            switch self {
            case .changedMeanwhile:
                "Claude Code changed its settings at the same moment. Nothing was written; try again."
            }
        }
    }

    /// Where a write to `destination` lands. An atomic write renames a new
    /// file over its destination, so written to a symlink (settings kept in a
    /// dotfiles repository) it would replace the link with a plain file and
    /// leave the real file behind, unedited. The link's target is written
    /// instead, and the link stays a link.
    public static func target(for destination: URL) -> URL {
        destination.resolvingSymlinksInPath()
    }

    /// Throws when the file no longer holds the bytes the caller planned its
    /// change from. Claude Code writes this file too; writing over a newer
    /// version would silently undo that change.
    public static func requireUnchanged(
        _ destination: URL,
        since existingData: Data?,
        fileManager: FileManager = .default
    ) throws {
        let target = target(for: destination)
        let current = fileManager.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        guard current == existingData else { throw WriteError.changedMeanwhile }
    }

    /// Atomically replaces the file's contents, keeping its permissions (a
    /// new file is private to the owner). Refused if the file changed since
    /// `existingData` was read.
    public static func replace(
        _ destination: URL,
        with data: Data,
        expecting existingData: Data?,
        fileManager: FileManager = .default
    ) throws {
        let target = target(for: destination)
        let permissions = fileManager.fileExists(atPath: target.path)
            ? try fileManager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
            : nil
        try requireUnchanged(destination, since: existingData, fileManager: fileManager)
        try data.write(to: target, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: permissions ?? NSNumber(value: 0o600)],
            ofItemAtPath: target.path
        )
    }
}
