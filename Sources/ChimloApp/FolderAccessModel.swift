import ChimloCore
import Foundation

/// Remembers which protected folders (Documents, Desktop, …) the owner has
/// let Overhead's git reads into. Until a folder is confirmed, git there runs
/// only from an explicit button, because macOS shows its permission prompt
/// the moment git touches the folder, and git blocks until it is answered.
@MainActor
final class FolderAccessModel: ObservableObject {
    @Published private(set) var confirmedRoots: Set<String>
    private let defaults: UserDefaults
    private let home: String
    static let storageKey = "overhead.folderAccess.confirmedRoots"
    /// Long enough for the owner to read and answer the macOS prompt.
    static let promptTimeout: TimeInterval = 120

    init(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        self.defaults = defaults
        self.home = home
        confirmedRoots = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    /// The protected folder `path` is in, when the owner has not allowed it yet.
    func pendingRoot(for path: String) -> String? {
        guard let root = FolderAccess.protectedRoot(for: path, home: home),
              !confirmedRoots.contains(root) else { return nil }
        return root
    }

    func needsConfirmation(for path: String) -> Bool {
        pendingRoot(for: path) != nil
    }

    /// Called after git succeeded in `path`, which means macOS allowed it.
    func recordSuccess(for path: String) {
        guard let root = FolderAccess.protectedRoot(for: path, home: home),
              confirmedRoots.insert(root).inserted else { return }
        defaults.set(confirmedRoots.sorted(), forKey: Self.storageKey)
    }

    static func displayName(for root: String) -> String {
        switch root {
        case "Library/Mobile Documents": "iCloud Drive"
        case "Volumes": "external or network volumes"
        default: root
        }
    }
}
