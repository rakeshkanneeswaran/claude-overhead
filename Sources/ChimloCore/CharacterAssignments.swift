import Foundation

/// What one session shows in place of the Claude mark.
public enum CharacterChoice: Equatable, Codable, Sendable {
    /// A character, by its catalogue id.
    case character(String)
    /// The owner turned the character off for this session.
    case none

    private enum CodingKeys: String, CodingKey { case character, none }

    /// A shape this version does not know is an error, not "none": the
    /// record is then skipped, instead of a choice made by a newer version
    /// being read as "the owner chose the Claude logo" and saved back as that.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .character) {
            self = .character(id)
        } else if try container.decodeIfPresent(Bool.self, forKey: .none) == true {
            self = .none
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown character choice"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .character(id): try container.encode(id, forKey: .character)
        case .none: try container.encode(true, forKey: .none)
        }
    }
}

public struct CharacterAssignment: Equatable, Codable, Sendable {
    public var choice: CharacterChoice
    /// True when the owner chose it in the notch: a character, a random one
    /// they asked for, or the Claude logo. False for one handed out by
    /// automatic assignment, which shows only while that setting is on.
    public var chosenByOwner: Bool
    /// When the session was last listed; the oldest records are dropped first.
    public var lastSeenAt: Date

    public init(choice: CharacterChoice, chosenByOwner: Bool, lastSeenAt: Date) {
        self.choice = choice
        self.chosenByOwner = chosenByOwner
        self.lastSeenAt = lastSeenAt
    }
}

/// A session as the assigner sees it.
public struct CharacterSession: Equatable, Sendable {
    public let id: String
    public let projectKey: String?

    public init(id: String, projectPath: String?) {
        self.id = id
        self.projectKey = ProjectKey.make(projectPath)
    }
}

/// Which character each session wears.
///
/// A session shows the Claude logo unless it has a character. It gets one in
/// two ways: the owner picks it in the notch, which always shows; or, when
/// the owner has turned automatic assignment on, a new session draws one at
/// random. A character handed out automatically shows only while that setting
/// is on, and is kept, not erased, while it is off.
///
/// A session keeps its character for as long as it is remembered, across
/// refreshes and restarts, and gets the same one back if it is resumed. Only
/// the sessions listed right now count as "in use", so a character is free
/// again as soon as its session leaves the list.
public struct CharacterAssignments: Equatable, Codable, Sendable {
    /// Sessions remembered, listed or not. Enough for a resumed session to
    /// find its character again without the file growing for ever.
    public static let maximumRemembered = 512
    /// How stale `lastSeenAt` may get before it is written again, so a
    /// refresh every second is not a write every second.
    static let lastSeenResolution: TimeInterval = 3_600

    public private(set) var bySession: [String: CharacterAssignment]

    public init(bySession: [String: CharacterAssignment] = [:]) {
        self.bySession = bySession
    }

    private enum CodingKeys: String, CodingKey { case bySession }

    /// One record that cannot be read is dropped by itself. The rest, the
    /// owner's picks among them, are kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let records = try container.decode([String: Readable<CharacterAssignment>].self, forKey: .bySession)
        bySession = records.compactMapValues(\.value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bySession, forKey: .bySession)
    }

    private struct Readable<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    /// The character stored for a session, whoever chose it; nil when none
    /// is stored, the owner chose the Claude logo, or this version lacks it.
    public func character(for sessionID: String) -> SessionCharacter? {
        guard case let .character(id)? = bySession[sessionID]?.choice else { return nil }
        return CharacterCatalog.character(id: id)
    }

    /// What a session shows: its character, or nil for the Claude logo. The
    /// owner's own pick always shows. One handed out automatically shows only
    /// while automatic assignment is on.
    public func shownCharacter(for sessionID: String, automatic: Bool) -> SessionCharacter? {
        guard let assignment = bySession[sessionID], automatic || assignment.chosenByOwner else { return nil }
        return character(for: sessionID)
    }

    public func choice(for sessionID: String) -> CharacterChoice? { bySession[sessionID]?.choice }

    /// Notes that the listed sessions were seen and, when `automatic` is on,
    /// gives a character to every listed session that has none. With it off
    /// nothing is handed out: a session shows the Claude logo until the owner
    /// picks a character for it. Returns whether anything changed.
    ///
    /// `pools` holds each project's approved characters by project key. A
    /// project with no pool, or one with no character this version knows,
    /// draws from the whole catalogue.
    @discardableResult
    public mutating func assign<Generator: RandomNumberGenerator>(
        sessions: [CharacterSession],
        pools: [String: [String]],
        automatic: Bool,
        now: Date,
        using generator: inout Generator
    ) -> Bool {
        var changed = false
        for session in sessions {
            // The owner's choice stands whatever it is. An automatic one is
            // replaced only if this version no longer has that character.
            if var existing = bySession[session.id],
               existing.chosenByOwner || !automatic || Self.isUsable(existing.choice) {
                if now.timeIntervalSince(existing.lastSeenAt) >= Self.lastSeenResolution
                    || existing.lastSeenAt > now {
                    existing.lastSeenAt = now
                    bySession[session.id] = existing
                    changed = true
                }
                continue
            }
            guard automatic,
                  let id = pick(for: session, among: sessions, pools: pools, using: &generator) else { continue }
            bySession[session.id] = CharacterAssignment(choice: .character(id), chosenByOwner: false, lastSeenAt: now)
            changed = true
        }
        if prune(keeping: Set(sessions.map(\.id))) { changed = true }
        return changed
    }

    /// The owner picked a character for this session.
    public mutating func choose(_ characterID: String, for sessionID: String, now: Date) {
        guard CharacterCatalog.character(id: characterID) != nil else { return }
        bySession[sessionID] = CharacterAssignment(choice: .character(characterID), chosenByOwner: true, lastSeenAt: now)
        prune(keeping: [sessionID])
    }

    /// The owner switched this session back to the Claude logo. Automatic
    /// assignment leaves it alone from then on. Returns whether anything
    /// changed.
    ///
    /// A session already on the logo with nothing of the owner's to undo is
    /// left exactly as it is. Otherwise a click on the logo that is already
    /// showing would erase a character waiting behind a switched-off
    /// automatic setting, or opt the session out of automatic assignment
    /// with nothing on screen to say so.
    @discardableResult
    public mutating func useClaudeLogo(for sessionID: String, automatic: Bool, now: Date) -> Bool {
        guard let existing = bySession[sessionID],
              existing.chosenByOwner || automatic,
              existing.choice != .none else { return false }
        bySession[sessionID] = CharacterAssignment(choice: .none, chosenByOwner: true, lastSeenAt: now)
        prune(keeping: [sessionID])
        return true
    }

    /// The owner asked for a random character for one session: a new one,
    /// different from its current one where the pool allows. It counts as the
    /// owner's choice, so it shows whether or not automatic assignment is on.
    public mutating func reshuffle<Generator: RandomNumberGenerator>(
        _ session: CharacterSession,
        among sessions: [CharacterSession],
        pools: [String: [String]],
        now: Date,
        using generator: inout Generator
    ) {
        var current: String?
        if case let .character(id)? = bySession[session.id]?.choice { current = id }
        bySession.removeValue(forKey: session.id)
        guard let id = pick(for: session, among: sessions, pools: pools, avoiding: current, using: &generator)
        else { return }
        bySession[session.id] = CharacterAssignment(choice: .character(id), chosenByOwner: true, lastSeenAt: now)
        prune(keeping: Set(sessions.map(\.id)).union([session.id]))
    }

    // MARK: Picking

    /// The characters a session may be given: its project's pool, or the
    /// whole catalogue when the project has none that this version knows.
    public static func pool(forProject projectKey: String?, pools: [String: [String]]) -> [String] {
        if let projectKey, let configured = pools[projectKey] {
            let known = CharacterCatalog.knownIDs(in: configured)
            if !known.isEmpty { return known }
        }
        return CharacterCatalog.all.map(\.id)
    }

    /// A stored choice still means something: "off" always does, a character
    /// only while the catalogue has it.
    private static func isUsable(_ choice: CharacterChoice) -> Bool {
        switch choice {
        case .none: true
        case let .character(id): CharacterCatalog.character(id: id) != nil
        }
    }

    /// Prefers a character no listed session wears; then one no session of
    /// the same project wears; then, with the pool used up, the one worn
    /// least. Ties are settled at random.
    private func pick<Generator: RandomNumberGenerator>(
        for session: CharacterSession,
        among sessions: [CharacterSession],
        pools: [String: [String]],
        avoiding avoided: String? = nil,
        using generator: inout Generator
    ) -> String? {
        var pool = Self.pool(forProject: session.projectKey, pools: pools)
        if let avoided, pool.count > 1 { pool.removeAll { $0 == avoided } }
        guard !pool.isEmpty else { return nil }

        var wornAnywhere: [String: Int] = [:]
        var wornInProject: [String: Int] = [:]
        for other in sessions where other.id != session.id {
            // Every listed session's character counts as worn, the owner's
            // picks included, so a new one avoids them all.
            guard case let .character(id)? = bySession[other.id]?.choice else { continue }
            wornAnywhere[id, default: 0] += 1
            if other.projectKey == session.projectKey { wornInProject[id, default: 0] += 1 }
        }

        let free = pool.filter { wornAnywhere[$0] == nil }
        if let pick = free.randomElement(using: &generator) { return pick }

        let freeInProject = pool.filter { wornInProject[$0] == nil }
        let candidates = freeInProject.isEmpty ? pool : freeInProject
        let counts = freeInProject.isEmpty ? wornInProject : wornAnywhere
        let fewest = candidates.map { counts[$0, default: 0] }.min() ?? 0
        return candidates.filter { counts[$0, default: 0] == fewest }.randomElement(using: &generator)
    }

    /// Forgets the least valuable records beyond the limit: never one of
    /// `listed` (a session on screen keeps its character whatever else
    /// happens), automatic ones before the owner's picks, oldest first.
    @discardableResult
    private mutating func prune(keeping listed: Set<String>) -> Bool {
        let excess = bySession.count - Self.maximumRemembered
        guard excess > 0 else { return false }
        let forgettable = bySession.filter { !listed.contains($0.key) }.sorted { lhs, rhs in
            if lhs.value.chosenByOwner != rhs.value.chosenByOwner { return !lhs.value.chosenByOwner }
            if lhs.value.lastSeenAt != rhs.value.lastSeenAt { return lhs.value.lastSeenAt < rhs.value.lastSeenAt }
            return lhs.key < rhs.key
        }
        guard !forgettable.isEmpty else { return false }
        for (id, _) in forgettable.prefix(excess) { bySession.removeValue(forKey: id) }
        return true
    }
}

/// Keeps the assignments in `UserDefaults` as one JSON blob. A record that
/// cannot be read is dropped by itself. Data that cannot be read at all is
/// set aside under `corruptBackupKey`, as the settings store does, and the
/// app starts with nothing assigned: every session shows the Claude logo.
public struct CharacterAssignmentStore {
    public static let storageKey = "overhead.characters.assignments.v1"
    public static let corruptBackupKey = "overhead.characters.assignments.v1.corrupt"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CharacterAssignments {
        guard let data = defaults.data(forKey: Self.storageKey) else { return CharacterAssignments() }
        guard let decoded = try? JSONDecoder().decode(CharacterAssignments.self, from: data) else {
            defaults.set(data, forKey: Self.corruptBackupKey)
            return CharacterAssignments()
        }
        return decoded
    }

    public func save(_ assignments: CharacterAssignments) {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
