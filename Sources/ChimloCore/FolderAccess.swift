import Foundation

/// Folders macOS guards with a "Files and Folders" privacy prompt. Running
/// git inside one makes macOS ask the owner on Overhead's behalf, and the
/// git process blocks until they answer. Overhead reads git there only after
/// the owner asks it to, so the prompt never appears out of nowhere.
public enum FolderAccess {
    /// Folders under the home directory that macOS protects.
    public static let protectedHomeFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]

    public static func isProtected(path: String, home: String) -> Bool {
        protectedRoot(for: path, home: home) != nil
    }

    /// The protected folder `path` lives in ("Documents", "Volumes", …), or
    /// nil. macOS asks once per folder, so this is what to remember.
    public static func protectedRoot(for path: String, home: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        let homePath = (home as NSString).standardizingPath
        // Other volumes (external, network) prompt as "removable" or
        // "network" volumes.
        if standardized.hasPrefix("/Volumes/") { return "Volumes" }
        return protectedHomeFolders.first { folder in
            let root = homePath + "/" + folder
            return standardized == root || standardized.hasPrefix(root + "/")
        }
    }
}
