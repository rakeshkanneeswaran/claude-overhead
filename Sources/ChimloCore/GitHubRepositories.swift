import Foundation

/// A GitHub repository the owner can monitor.
///
/// `id` is GitHub's numeric repository id. It survives renames and transfers,
/// and two repositories that share a name under different owners never
/// collide, which a "name" or "owner/name" key cannot promise.
public struct GitHubRepoRef: Codable, Hashable, Sendable, Identifiable {
    public let id: Int64
    public var owner: String
    public var name: String
    /// Nil when GitHub has not told us yet (a repository found from a git
    /// remote before its first API response).
    public var isPrivate: Bool?

    public var fullName: String { "\(owner)/\(name)" }

    public init(id: Int64, owner: String, name: String, isPrivate: Bool? = nil) {
        self.id = id
        self.owner = owner
        self.name = name
        self.isPrivate = isPrivate
    }

    public var remote: GitRemote {
        GitRemote(host: "github.com", owner: owner, name: name)
    }
}

/// Whether a monitored repository answered its last refresh.
public enum GitHubRepoAvailability: Equatable, Sendable {
    case unknown
    case available
    /// Deleted, made private to someone else, or never visible to this token.
    /// GitHub answers all three with 404, so Overhead cannot tell them apart.
    case notFound
    /// The token can see the repository but may not read this part of it,
    /// such as a fine-grained token without Actions access.
    case forbidden(String?)
    /// A network or server problem; the repository may be fine.
    case failed(String)

    public var isUnavailable: Bool {
        switch self {
        case .notFound, .forbidden: true
        default: false
        }
    }
}

/// Which repositories Overhead monitors, and which one is shown in detail.
///
/// The selection is a collection of repository identities, not one id, and
/// every operation keeps three invariants:
/// - each repository appears once (by `id`),
/// - `focusedID` is one of the selected repositories, or nil when none are,
/// - a repository the owner removed stays out of automatic adding until the
///   owner adds it again by hand.
public struct GitHubRepositorySelection: Codable, Equatable, Sendable {
    /// Monitored repositories, in the order they were added.
    public private(set) var repositories: [GitHubRepoRef]
    /// The repository GitHub Mode shows in detail.
    public private(set) var focusedID: Int64?
    /// Removed by the owner. `adoptClaudeRepositories` never brings these back.
    public private(set) var excludedIDs: Set<Int64>
    /// Add repositories that Claude works in (found from git remotes in Claude
    /// project folders) automatically. On by default, so the behaviour before
    /// repository selection existed carries on unchanged.
    public var followClaudeRepositories: Bool

    public init(
        repositories: [GitHubRepoRef] = [],
        focusedID: Int64? = nil,
        excludedIDs: Set<Int64> = [],
        followClaudeRepositories: Bool = true
    ) {
        self.repositories = []
        self.focusedID = nil
        self.excludedIDs = excludedIDs
        self.followClaudeRepositories = followClaudeRepositories
        for repository in repositories { insert(repository) }
        self.excludedIDs.subtract(self.repositories.map(\.id))
        self.focusedID = focusedID
        normalizeFocus()
    }

    public var isEmpty: Bool { repositories.isEmpty }
    public var count: Int { repositories.count }
    public var ids: [Int64] { repositories.map(\.id) }

    public func contains(_ id: Int64) -> Bool {
        repositories.contains { $0.id == id }
    }

    public var focused: GitHubRepoRef? {
        guard let focusedID else { return nil }
        return repositories.first { $0.id == focusedID }
    }

    /// Adds a repository by hand. Adding something already selected only
    /// refreshes its name; adding a removed one lifts its exclusion.
    public mutating func select(_ repository: GitHubRepoRef) {
        excludedIDs.remove(repository.id)
        insert(repository)
        normalizeFocus()
    }

    public mutating func deselect(_ id: Int64) {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        repositories.remove(at: index)
        excludedIDs.insert(id)
        normalizeFocus()
    }

    public mutating func toggle(_ repository: GitHubRepoRef) {
        if contains(repository.id) {
            deselect(repository.id)
        } else {
            select(repository)
        }
    }

    /// Selects every repository given, such as everything a search shows.
    public mutating func select(all candidates: [GitHubRepoRef]) {
        for repository in candidates { select(repository) }
    }

    /// Deselects every repository given, leaving others selected.
    public mutating func deselect(all candidates: [GitHubRepoRef]) {
        for repository in candidates { deselect(repository.id) }
    }

    /// Removes everything. Each removed repository is excluded, so
    /// "follow Claude repositories" does not refill the list on the next poll.
    public mutating func clear() {
        excludedIDs.formUnion(repositories.map(\.id))
        repositories.removeAll()
        focusedID = nil
    }

    /// Focuses a selected repository; anything else is ignored.
    public mutating func focus(_ id: Int64) {
        guard contains(id) else { return }
        focusedID = id
    }

    /// Adds repositories Claude works in, unless the owner removed them or
    /// following is off. Returns what was added.
    @discardableResult
    public mutating func adoptClaudeRepositories(_ candidates: [GitHubRepoRef]) -> [GitHubRepoRef] {
        guard followClaudeRepositories else { return [] }
        var added: [GitHubRepoRef] = []
        for repository in candidates where !contains(repository.id) && !excludedIDs.contains(repository.id) {
            insert(repository)
            added.append(repository)
        }
        normalizeFocus()
        return added
    }

    /// Applies what GitHub now says about a selected repository (a rename, a
    /// transfer, a visibility change), keeping its place and selection.
    public mutating func refresh(_ repository: GitHubRepoRef) {
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }
        var updated = repository
        if updated.isPrivate == nil { updated.isPrivate = repositories[index].isPrivate }
        repositories[index] = updated
    }

    private mutating func insert(_ repository: GitHubRepoRef) {
        if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
            var updated = repository
            if updated.isPrivate == nil { updated.isPrivate = repositories[index].isPrivate }
            repositories[index] = updated
        } else {
            repositories.append(repository)
        }
    }

    private mutating func normalizeFocus() {
        if let focusedID, contains(focusedID) { return }
        focusedID = repositories.first?.id
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case repositories, focusedID, excludedIDs, followClaudeRepositories
    }

    /// Lenient: one unreadable repository entry is dropped on its own instead
    /// of discarding the whole selection.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? container.decode([Lossy<GitHubRepoRef>].self, forKey: .repositories)) ?? []
        self.init(
            repositories: entries.compactMap(\.value),
            focusedID: container.lenient(Int64.self, .focusedID),
            excludedIDs: Set(container.lenient([Int64].self, .excludedIDs) ?? []),
            followClaudeRepositories: container.lenient(Bool.self, .followClaudeRepositories) ?? true
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repositories, forKey: .repositories)
        try container.encodeIfPresent(focusedID, forKey: .focusedID)
        try container.encode(excludedIDs.sorted(), forKey: .excludedIDs)
        try container.encode(followClaudeRepositories, forKey: .followClaudeRepositories)
    }
}

/// Decodes one element, or nothing when it is malformed.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Filters the repository picker. Matches owner, name or "owner/name",
/// ignoring case, so "acme/api" and "api" both find acme/api.
public enum GitHubRepoSearch {
    public static func filter(_ repositories: [GitHubRepoRef], query: String) -> [GitHubRepoRef] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return repositories }
        return repositories.filter { $0.fullName.lowercased().contains(needle) }
    }

    /// Repositories grouped by owner (person or organization), owners sorted
    /// with the viewer first, repositories sorted by name.
    public static func groupedByOwner(
        _ repositories: [GitHubRepoRef],
        viewer: String?
    ) -> [(owner: String, repositories: [GitHubRepoRef])] {
        let groups = Dictionary(grouping: repositories, by: \.owner)
        let viewerKey = viewer?.lowercased()
        let owners = groups.keys.sorted { lhs, rhs in
            let lhsViewer = lhs.lowercased() == viewerKey
            let rhsViewer = rhs.lowercased() == viewerKey
            if lhsViewer != rhsViewer { return lhsViewer }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return owners.map { owner in
            (owner, (groups[owner] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }
}
