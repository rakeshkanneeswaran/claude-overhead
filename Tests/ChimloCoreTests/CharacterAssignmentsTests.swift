import Foundation
import Testing
@testable import ChimloCore

/// A small repeatable generator, so "random" assignments can be tested.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Suite("Character assignment")
struct CharacterAssignmentsTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)
    private static let catalogCount = CharacterCatalog.all.count

    private static func session(_ id: String, project: String? = "/work/app") -> CharacterSession {
        CharacterSession(id: id, projectPath: project)
    }

    private static func sessions(_ count: Int, project: String? = "/work/app") -> [CharacterSession] {
        (0..<count).map { session("s\($0)", project: project) }
    }

    private static func worn(_ assignments: CharacterAssignments, by sessions: [CharacterSession]) -> [String] {
        sessions.compactMap { assignments.character(for: $0.id)?.id }
    }

    // MARK: The default: the Claude logo

    @Test("By default nothing is assigned: every session shows the Claude logo")
    func defaultIsTheClaudeLogo() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 21)
        let listed = Self.sessions(8)
        for step in 0..<5 {
            let changed = assignments.assign(sessions: listed, pools: ["/work/app": ["animals.cat"]], automatic: false,
                                             now: Self.base.addingTimeInterval(Double(step) * 5_000), using: &generator)
            #expect(!changed)
        }
        #expect(assignments.bySession.isEmpty)
        for session in listed {
            #expect(assignments.shownCharacter(for: session.id, automatic: false) == nil)
            #expect(assignments.shownCharacter(for: session.id, automatic: true) == nil)
        }
    }

    @Test("A character the owner picks shows at once, with automatic assignment off or on")
    func manualPickAlwaysShows() throws {
        var assignments = CharacterAssignments()
        assignments.choose("cyber.ufo", for: "a", now: Self.base)
        #expect(assignments.shownCharacter(for: "a", automatic: false)?.id == "cyber.ufo")
        #expect(assignments.shownCharacter(for: "a", automatic: true)?.id == "cyber.ufo")
        // The other sessions are untouched.
        #expect(assignments.shownCharacter(for: "b", automatic: false) == nil)

        // And it is still there after a restart.
        let restored = try JSONDecoder().decode(CharacterAssignments.self, from: JSONEncoder().encode(assignments))
        #expect(restored.shownCharacter(for: "a", automatic: false)?.id == "cyber.ufo")
        #expect(restored.bySession["a"]?.chosenByOwner == true)
    }

    @Test("A random character the owner asks for counts as their pick")
    func surpriseMeIsAPick() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 22)
        let only = Self.session("a")
        assignments.reshuffle(only, among: [only], pools: [:], now: Self.base, using: &generator)
        #expect(assignments.bySession["a"]?.chosenByOwner == true)
        #expect(assignments.shownCharacter(for: "a", automatic: false) != nil)
    }

    @Test("Turning automatic assignment on gives the others a character and leaves the owner's picks alone")
    func turningAutomaticOn() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 23)
        let listed = Self.sessions(6)
        assignments.choose("cyber.ufo", for: "s0", now: Self.base)
        // The owner gave this one a character and then took it off again.
        assignments.choose("animals.cat", for: "s1", now: Self.base)
        assignments.useClaudeLogo(for: "s1", automatic: false, now: Self.base)

        #expect(assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base, using: &generator))
        #expect(assignments.shownCharacter(for: "s0", automatic: true)?.id == "cyber.ufo")
        // The owner said Claude logo for this one; automatic leaves it be.
        #expect(assignments.shownCharacter(for: "s1", automatic: true) == nil)
        let others = listed.dropFirst(2).compactMap { assignments.shownCharacter(for: $0.id, automatic: true)?.id }
        #expect(others.count == 4)
        #expect(Set(others).count == 4)
        // None of them took the character the owner picked for s0.
        #expect(!others.contains("cyber.ufo"))
    }

    @Test("Turning it off puts automatic characters back on the Claude logo without erasing anything")
    func turningAutomaticOff() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 24)
        let listed = Self.sessions(5)
        assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base, using: &generator)
        assignments.choose("fantasy.yeti", for: "s0", now: Self.base)
        let whileOn = listed.map { assignments.shownCharacter(for: $0.id, automatic: true)?.id }

        // Off: refreshes go on, nothing new is handed out, nothing is erased.
        let stored = assignments
        for step in 1...3 {
            assignments.assign(sessions: listed + [Self.session("new")], pools: [:], automatic: false,
                               now: Self.base.addingTimeInterval(Double(step)), using: &generator)
        }
        #expect(assignments == stored)
        #expect(assignments.shownCharacter(for: "s0", automatic: false)?.id == "fantasy.yeti")
        for session in listed.dropFirst() {
            #expect(assignments.shownCharacter(for: session.id, automatic: false) == nil)
        }
        #expect(assignments.bySession["new"] == nil)

        // On again: every session shows what it showed before.
        assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base.addingTimeInterval(10), using: &generator)
        #expect(listed.map { assignments.shownCharacter(for: $0.id, automatic: true)?.id } == whileOn)
    }

    @Test("With automatic assignment off, a project's collection hands out nothing")
    func poolNeedsAutomatic() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 25)
        let listed = Self.sessions(3, project: "/work/game")
        assignments.assign(sessions: listed, pools: ["/work/game": ["fantasy.slime"]], automatic: false, now: Self.base, using: &generator)
        #expect(assignments.bySession.isEmpty)
        // The owner may still pick any character, in the collection or not.
        assignments.choose("cyber.ufo", for: "s0", now: Self.base)
        #expect(assignments.shownCharacter(for: "s0", automatic: false)?.id == "cyber.ufo")
    }

    @Test("The owner's pick is never replaced, even if this version lacks that character")
    func ownerPickIsNeverReplaced() {
        var assignments = CharacterAssignments(bySession: [
            "a": CharacterAssignment(choice: .character("from.a.newer.version"), chosenByOwner: true, lastSeenAt: Self.base),
        ])
        var generator = SeededGenerator(seed: 26)
        assignments.assign(sessions: [Self.session("a")], pools: [:], automatic: true, now: Self.base, using: &generator)
        #expect(assignments.bySession["a"]?.choice == .character("from.a.newer.version"))
        // It shows the Claude logo here, the fallback whenever there is no character to draw.
        #expect(assignments.shownCharacter(for: "a", automatic: true) == nil)
    }

    // MARK: Automatic assignment

    @Test("Every new session gets a character, and no two listed sessions share one")
    func uniqueWhilePoolLasts() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 1)
        let listed = Self.sessions(Self.catalogCount)
        #expect(assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base, using: &generator))
        let worn = Self.worn(assignments, by: listed)
        #expect(worn.count == Self.catalogCount)
        #expect(Set(worn).count == Self.catalogCount)
    }

    @Test("With the pool used up, the extra sessions share as evenly as possible")
    func exhaustedPool() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 2)
        let listed = Self.sessions(Self.catalogCount + 5)
        assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base, using: &generator)
        let counts = Dictionary(grouping: Self.worn(assignments, by: listed), by: { $0 }).mapValues(\.count)
        #expect(counts.count == Self.catalogCount)
        #expect(counts.values.max() == 2)
        #expect(counts.values.filter { $0 == 2 }.count == 5)
    }

    @Test("The choice is random: different runs give the first session different characters")
    func isRandom() {
        var first = Set<String>()
        for seed in 0..<200 {
            var assignments = CharacterAssignments()
            var generator = SeededGenerator(seed: UInt64(seed))
            assignments.assign(sessions: Self.sessions(1), pools: [:], automatic: true, now: Self.base, using: &generator)
            if let id = assignments.character(for: "s0")?.id { first.insert(id) }
        }
        #expect(first.count > 20)
    }

    @Test("A session keeps its character through refreshes and a restart")
    func sticky() throws {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 3)
        let listed = Self.sessions(6)
        assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base, using: &generator)
        let before = Self.worn(assignments, by: listed)

        // Refreshes, with the list in another order and a different generator.
        var other = SeededGenerator(seed: 99)
        for step in 1...20 {
            assignments.assign(sessions: listed.shuffled(using: &other), pools: [:], automatic: true,
                               now: Self.base.addingTimeInterval(Double(step)), using: &other)
        }
        #expect(Self.worn(assignments, by: listed) == before)

        // The app restarts: the same data comes back from disk.
        let restored = try JSONDecoder().decode(CharacterAssignments.self, from: JSONEncoder().encode(assignments))
        #expect(restored == assignments)
        #expect(Self.worn(restored, by: listed) == before)
    }

    @Test("A refresh that changes nothing reports no change, so nothing is written")
    func quietRefresh() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 4)
        let listed = Self.sessions(3)
        #expect(assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base, using: &generator))
        #expect(!assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base.addingTimeInterval(30), using: &generator))
        // Long enough for "last seen" to be worth noting again.
        #expect(assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base.addingTimeInterval(4_000), using: &generator))
    }

    @Test("A character is free again once its session leaves the list")
    func freedWhenSessionEnds() {
        let pool = ["animals.cat", "animals.dog"]
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 5)
        let a = Self.session("a"), b = Self.session("b"), c = Self.session("c")
        assignments.assign(sessions: [a, b], pools: ["/work/app": pool], automatic: true, now: Self.base, using: &generator)
        let aCharacter = assignments.character(for: "a")?.id
        let bCharacter = assignments.character(for: "b")?.id
        #expect(Set([aCharacter, bCharacter]) == Set(pool.map(Optional.some)))

        // a ends; c starts and takes the one a wore, not the one b still wears.
        assignments.assign(sessions: [b, c], pools: ["/work/app": pool], automatic: true, now: Self.base.addingTimeInterval(10), using: &generator)
        #expect(assignments.character(for: "c")?.id == aCharacter)
        #expect(assignments.character(for: "b")?.id == bCharacter)

        // a is resumed: it gets its own character back, even though c wears it now.
        assignments.assign(sessions: [a, b, c], pools: ["/work/app": pool], automatic: true, now: Self.base.addingTimeInterval(20), using: &generator)
        #expect(assignments.character(for: "a")?.id == aCharacter)
    }

    // MARK: Project pools

    @Test("A project with a pool draws only from it, without repeats while it lasts")
    func projectPool() {
        let pool = ["fantasy.slime", "fantasy.yeti", "cyber.ufo"]
        for seed in 0..<40 {
            var assignments = CharacterAssignments()
            var generator = SeededGenerator(seed: UInt64(seed))
            let listed = Self.sessions(3, project: "/work/game")
            assignments.assign(sessions: listed, pools: ["/work/game": pool], automatic: true, now: Self.base, using: &generator)
            #expect(Set(Self.worn(assignments, by: listed)) == Set(pool))
        }
    }

    @Test("A used-up project pool repeats its characters evenly, never leaving the pool")
    func projectPoolExhausted() {
        let pool = ["fantasy.slime", "fantasy.yeti"]
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 7)
        let listed = Self.sessions(6, project: "/work/game")
        assignments.assign(sessions: listed, pools: ["/work/game": pool], automatic: true, now: Self.base, using: &generator)
        let counts = Dictionary(grouping: Self.worn(assignments, by: listed), by: { $0 }).mapValues(\.count)
        #expect(counts == ["fantasy.slime": 3, "fantasy.yeti": 3])
    }

    @Test("An empty pool, or one of ids this version lacks, means the whole collection")
    func emptyOrUnknownPool() {
        #expect(CharacterAssignments.pool(forProject: "/p", pools: ["/p": []]).count == Self.catalogCount)
        #expect(CharacterAssignments.pool(forProject: "/p", pools: ["/p": ["from.a.newer.version"]]).count == Self.catalogCount)
        #expect(CharacterAssignments.pool(forProject: "/p", pools: [:]).count == Self.catalogCount)
        #expect(CharacterAssignments.pool(forProject: nil, pools: ["/p": ["animals.cat"]]).count == Self.catalogCount)
        #expect(CharacterAssignments.pool(forProject: "/p", pools: ["/p": ["animals.cat", "nope", "animals.cat"]]) == ["animals.cat"])

        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 8)
        assignments.assign(sessions: [Self.session("a", project: nil)], pools: ["/p": ["animals.cat"]], automatic: true, now: Self.base, using: &generator)
        #expect(assignments.character(for: "a") != nil)
    }

    @Test("Projects are told apart by their folder, however the path is written")
    func projectIdentity() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 9)
        let listed = [
            CharacterSession(id: "a", projectPath: "/work/game/"),
            CharacterSession(id: "b", projectPath: "/work/./game"),
            CharacterSession(id: "c", projectPath: "/work/other"),
        ]
        assignments.assign(sessions: listed, pools: ["/work/game": ["cyber.ufo"]], automatic: true, now: Self.base, using: &generator)
        #expect(assignments.character(for: "a")?.id == "cyber.ufo")
        #expect(assignments.character(for: "b")?.id == "cyber.ufo")
        // Another project is not held to that pool, and avoids what is worn.
        #expect(assignments.character(for: "c")?.id != "cyber.ufo")
    }

    @Test("Changing a project's pool leaves the characters already worn alone")
    func poolEditKeepsAssignments() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 10)
        let listed = Self.sessions(2, project: "/work/game")
        assignments.assign(sessions: listed, pools: ["/work/game": ["fantasy.slime", "fantasy.yeti"]], automatic: true, now: Self.base, using: &generator)
        let before = Self.worn(assignments, by: listed)
        // The pool now has neither of them.
        let later = listed + [Self.session("new", project: "/work/game")]
        assignments.assign(sessions: later, pools: ["/work/game": ["cyber.ufo"]], automatic: true, now: Self.base.addingTimeInterval(5), using: &generator)
        #expect(Self.worn(assignments, by: listed) == before)
        #expect(assignments.character(for: "new")?.id == "cyber.ufo")
    }

    // MARK: The owner's choices

    @Test("A character picked by the owner, or the Claude logo chosen instead, is kept as chosen")
    func ownerChoices() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 11)
        let listed = Self.sessions(3)
        assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base, using: &generator)

        assignments.choose("cyber.ufo", for: "s0", now: Self.base)
        assignments.useClaudeLogo(for: "s1", automatic: true, now: Self.base)
        #expect(assignments.character(for: "s0")?.id == "cyber.ufo")
        #expect(assignments.character(for: "s1") == nil)
        #expect(assignments.choice(for: "s1") == CharacterChoice.none)
        #expect(assignments.bySession["s0"]?.chosenByOwner == true)

        // Later refreshes do not hand the session on the Claude logo a character.
        assignments.assign(sessions: listed, pools: [:], automatic: true, now: Self.base.addingTimeInterval(9_000), using: &generator)
        #expect(assignments.character(for: "s0")?.id == "cyber.ufo")
        #expect(assignments.character(for: "s1") == nil)

        // A character that does not exist is not stored.
        assignments.choose("fantasy.nobody", for: "s2", now: Self.base)
        #expect(assignments.character(for: "s2") != nil)
        #expect(assignments.character(for: "s2")?.id != "fantasy.nobody")
    }

    @Test("Shuffling draws a different character where the pool allows")
    func reshuffle() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 12)
        let only = Self.session("a")
        assignments.assign(sessions: [only], pools: [:], automatic: true, now: Self.base, using: &generator)
        for _ in 0..<20 {
            let before = assignments.character(for: "a")?.id
            assignments.reshuffle(only, among: [only], pools: [:], now: Self.base, using: &generator)
            #expect(assignments.character(for: "a") != nil)
            #expect(assignments.character(for: "a")?.id != before)
        }
        // A pool of one has nothing else to offer.
        assignments.reshuffle(only, among: [only], pools: ["/work/app": ["animals.cat"]], now: Self.base, using: &generator)
        assignments.reshuffle(only, among: [only], pools: ["/work/app": ["animals.cat"]], now: Self.base, using: &generator)
        #expect(assignments.character(for: "a")?.id == "animals.cat")
    }

    // MARK: Switching back to the Claude logo

    @Test("Claude logo on a session that already shows it changes nothing")
    func logoOnLogoIsANoOp() {
        var generator = SeededGenerator(seed: 31)
        // Nothing stored at all.
        var empty = CharacterAssignments()
        let changedWhenOff = empty.useClaudeLogo(for: "a", automatic: false, now: Self.base)
        let changedWhenOn = empty.useClaudeLogo(for: "a", automatic: true, now: Self.base)
        #expect(!changedWhenOff && !changedWhenOn)
        #expect(empty.bySession.isEmpty)

        // An automatic character waiting behind a switched-off setting: the
        // click must not erase it, so turning the setting on restores it.
        var hidden = CharacterAssignments()
        hidden.assign(sessions: [Self.session("a")], pools: [:], automatic: true, now: Self.base, using: &generator)
        let before = hidden
        #expect(hidden.shownCharacter(for: "a", automatic: false) == nil)
        let changedHidden = hidden.useClaudeLogo(for: "a", automatic: false, now: Self.base)
        #expect(!changedHidden)
        #expect(hidden == before)
        #expect(hidden.shownCharacter(for: "a", automatic: true) != nil)

        // Already the owner's choice.
        var chosen = CharacterAssignments()
        chosen.choose("cyber.ufo", for: "a", now: Self.base)
        let first = chosen.useClaudeLogo(for: "a", automatic: false, now: Self.base)
        let second = chosen.useClaudeLogo(for: "a", automatic: false, now: Self.base)
        #expect(first && !second)
    }

    @Test("Claude logo takes off a character that is showing, picked or automatic")
    func logoRemovesWhatShows() {
        var generator = SeededGenerator(seed: 32)
        var assignments = CharacterAssignments()
        assignments.assign(sessions: Self.sessions(2), pools: [:], automatic: true, now: Self.base, using: &generator)
        assignments.choose("cyber.ufo", for: "s1", now: Self.base)

        let removedAutomatic = assignments.useClaudeLogo(for: "s0", automatic: true, now: Self.base)
        let removedPicked = assignments.useClaudeLogo(for: "s1", automatic: false, now: Self.base)
        #expect(removedAutomatic && removedPicked)
        for id in ["s0", "s1"] {
            #expect(assignments.shownCharacter(for: id, automatic: true) == nil)
            #expect(assignments.choice(for: id) == CharacterChoice.none)
            #expect(assignments.bySession[id]?.chosenByOwner == true)
        }
        // Automatic assignment leaves both alone from then on.
        assignments.assign(sessions: Self.sessions(2), pools: [:], automatic: true, now: Self.base.addingTimeInterval(9_000), using: &generator)
        #expect(assignments.shownCharacter(for: "s0", automatic: true) == nil)
    }

    // MARK: Which character is drawn

    @Test("A character free in this project is preferred to one this project already wears")
    func prefersFreeInProject() {
        // Both of the collection's characters are worn, one by this project
        // and one by another. The new session takes the one its own project
        // does not wear.
        let pools = ["/work/game": ["fantasy.slime", "fantasy.yeti"]]
        for seed in 0..<30 {
            var assignments = CharacterAssignments()
            assignments.choose("fantasy.slime", for: "mine", now: Self.base)
            assignments.choose("fantasy.yeti", for: "theirs", now: Self.base)
            var generator = SeededGenerator(seed: UInt64(seed))
            let listed = [
                Self.session("mine", project: "/work/game"),
                Self.session("theirs", project: "/work/other"),
                Self.session("new", project: "/work/game"),
            ]
            assignments.assign(sessions: listed, pools: pools, automatic: true, now: Self.base, using: &generator)
            #expect(assignments.character(for: "new")?.id == "fantasy.yeti")
        }
    }

    @Test("Surprise me avoids what the other listed sessions wear")
    func reshuffleAmongSeveral() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 33)
        let pool = ["animals.cat", "animals.dog", "animals.frog"]
        let listed = Self.sessions(3, project: "/work/app")
        assignments.choose("animals.cat", for: "s0", now: Self.base)
        assignments.choose("animals.dog", for: "s1", now: Self.base)
        // The first draw takes the one character nobody wears.
        assignments.reshuffle(listed[2], among: listed, pools: ["/work/app": pool], now: Self.base, using: &generator)
        #expect(assignments.character(for: "s2")?.id == "animals.frog")
        // Asked again, it changes: a click on Surprise me always shows
        // something new, even if that means sharing, and never leaves the
        // project's collection.
        for _ in 0..<10 {
            let before = assignments.character(for: "s2")?.id
            assignments.reshuffle(listed[2], among: listed, pools: ["/work/app": pool], now: Self.base, using: &generator)
            let after = assignments.character(for: "s2")?.id
            #expect(after != before)
            #expect(after.map(pool.contains) == true)
        }
    }

    // MARK: Old and damaged data

    @Test("A stored character this version lacks is replaced, not shown as nothing")
    func unknownStoredCharacter() {
        var assignments = CharacterAssignments(bySession: [
            "a": CharacterAssignment(choice: .character("from.a.newer.version"), chosenByOwner: false, lastSeenAt: Self.base),
        ])
        #expect(assignments.character(for: "a") == nil)
        var generator = SeededGenerator(seed: 13)
        #expect(assignments.assign(sessions: [Self.session("a")], pools: [:], automatic: true, now: Self.base, using: &generator))
        #expect(assignments.character(for: "a") != nil)
    }

    @Test("A session on screen is never forgotten, and the owner's picks go last")
    func pruningKeepsWhatMatters() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 34)
        let longRunning = Self.session("long-running")
        // Picked by hand long ago, and still listed.
        assignments.choose("cyber.ufo", for: "long-running", now: Self.base)
        // A picked character of a session that has since gone.
        assignments.choose("fantasy.yeti", for: "gone-but-picked", now: Self.base)

        // A burst of sessions, each listed beside the long-running one.
        let total = CharacterAssignments.maximumRemembered + 60
        for index in 0..<total {
            assignments.assign(
                sessions: [longRunning, Self.session("burst\(index)")],
                pools: [:], automatic: true,
                now: Self.base.addingTimeInterval(Double(index)), using: &generator
            )
        }
        #expect(assignments.bySession.count == CharacterAssignments.maximumRemembered)
        #expect(assignments.character(for: "long-running")?.id == "cyber.ufo")
        // Automatic records of sessions that left go before a pick does.
        #expect(assignments.character(for: "gone-but-picked")?.id == "fantasy.yeti")
        #expect(assignments.bySession["burst0"] == nil)
    }

    @Test("A clock set back does not strand a record as newest for ever")
    func futureLastSeen() {
        var assignments = CharacterAssignments(bySession: [
            "a": CharacterAssignment(choice: .character("animals.cat"), chosenByOwner: false,
                                     lastSeenAt: Self.base.addingTimeInterval(86_400)),
        ])
        var generator = SeededGenerator(seed: 35)
        #expect(assignments.assign(sessions: [Self.session("a")], pools: [:], automatic: true, now: Self.base, using: &generator))
        #expect(assignments.bySession["a"]?.lastSeenAt == Self.base)
    }

    @Test("One unreadable record is dropped and every other one is kept")
    func oneBadRecord() throws {
        let stored = Data(#"""
        {"bySession": {
          "picked": {"choice": {"character": "cyber.ufo"}, "chosenByOwner": true, "lastSeenAt": 800000000},
          "logo": {"choice": {"none": true}, "chosenByOwner": true, "lastSeenAt": 800000000},
          "wrong-date": {"choice": {"character": "animals.cat"}, "chosenByOwner": false, "lastSeenAt": "yesterday"},
          "no-owner-flag": {"choice": {"character": "animals.cat"}, "lastSeenAt": 800000000},
          "newer-shape": {"choice": {"sticker": "star"}, "chosenByOwner": true, "lastSeenAt": 800000000},
          "not-an-object": 7
        }}
        """#.utf8)
        let assignments = try JSONDecoder().decode(CharacterAssignments.self, from: stored)
        #expect(Set(assignments.bySession.keys) == ["picked", "logo"])
        #expect(assignments.shownCharacter(for: "picked", automatic: false)?.id == "cyber.ufo")
        #expect(assignments.choice(for: "logo") == CharacterChoice.none)
        // A choice this version cannot read is not turned into "Claude logo".
        #expect(assignments.bySession["newer-shape"] == nil)
    }

    @Test("Only the most recently seen sessions are remembered")
    func bounded() {
        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 14)
        let total = CharacterAssignments.maximumRemembered + 40
        for index in 0..<total {
            assignments.assign(sessions: [Self.session("old\(index)")], pools: [:], automatic: true,
                               now: Self.base.addingTimeInterval(Double(index)), using: &generator)
        }
        #expect(assignments.bySession.count == CharacterAssignments.maximumRemembered)
        #expect(assignments.bySession["old0"] == nil)
        #expect(assignments.bySession["old\(total - 1)"] != nil)
    }

    @Test("Assignments are saved and loaded, and unreadable data starts empty")
    func store() throws {
        let suite = "overhead.tests.characters.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CharacterAssignmentStore(defaults: defaults)
        #expect(store.load() == CharacterAssignments())

        var assignments = CharacterAssignments()
        var generator = SeededGenerator(seed: 15)
        assignments.assign(sessions: Self.sessions(4), pools: [:], automatic: true, now: Self.base, using: &generator)
        assignments.useClaudeLogo(for: "s3", automatic: true, now: Self.base)
        store.save(assignments)
        #expect(store.load() == assignments)

        // Data that cannot be read at all is set aside, not thrown away.
        let damaged = Data("not json".utf8)
        defaults.set(damaged, forKey: CharacterAssignmentStore.storageKey)
        #expect(store.load() == CharacterAssignments())
        #expect(defaults.data(forKey: CharacterAssignmentStore.corruptBackupKey) == damaged)
    }

    // MARK: Settings

    @Test("Automatic characters are off by default, and settings from before the feature still load")
    func settings() throws {
        #expect(!OverheadSettings().assignCharactersAutomatically)
        #expect(OverheadSettings().projectCharacterPools.isEmpty)

        let older = try JSONDecoder().decode(OverheadSettings.self, from: Data(#"{"version":1,"notchLocked":true}"#.utf8))
        #expect(!older.assignCharactersAutomatically)
        #expect(older.projectCharacterPools.isEmpty)
        #expect(older.notchLocked)

        var settings = OverheadSettings()
        settings.assignCharactersAutomatically = true
        settings.projectCharacterPools = ["/work/game": ["fantasy.slime", "cyber.ufo"]]
        let loaded = try JSONDecoder().decode(OverheadSettings.self, from: JSONEncoder().encode(settings))
        #expect(loaded.assignCharactersAutomatically)
        #expect(loaded.projectCharacterPools == ["/work/game": ["fantasy.slime", "cyber.ufo"]])

        // A value this version cannot read falls back to the default: off.
        let damaged = try JSONDecoder().decode(
            OverheadSettings.self,
            from: Data(#"{"assignCharactersAutomatically":"always","projectCharacterPools":"all"}"#.utf8)
        )
        #expect(!damaged.assignCharactersAutomatically)
        #expect(damaged.projectCharacterPools.isEmpty)
    }

    @Test("Saved pools are tidied: clean keys, no repeats, no empty pools")
    func normalizedPools() {
        var settings = OverheadSettings()
        settings.projectCharacterPools = [
            "/work/game/": ["fantasy.slime", "fantasy.slime", "", "from.a.newer.version"],
            "/work/empty": [],
            "   ": ["cyber.ufo"],
        ]
        let pools = settings.normalized().projectCharacterPools
        #expect(pools == ["/work/game": ["fantasy.slime", "from.a.newer.version"]])
        // Tidying twice changes nothing more, so saving settles at once.
        #expect(settings.normalized().normalized() == settings.normalized())

        // Size is bounded: no more projects, ids or id bytes than the caps.
        var many = OverheadSettings()
        for index in 0..<(OverheadSettings.maximumProjectCharacterPools + 30) {
            many.projectCharacterPools["/work/p\(index)"] = ["animals.cat"]
        }
        many.projectCharacterPools["/work/big"] = (0..<400).map { "id\($0)" } + [String(repeating: "x", count: 200)]
        let bounded = many.normalized().projectCharacterPools
        #expect(bounded.count == OverheadSettings.maximumProjectCharacterPools)
        #expect((bounded["/work/big"]?.count ?? 0) <= 256)
        #expect(bounded.values.allSatisfy { $0.allSatisfy { $0.utf8.count <= 128 } })
    }
}
