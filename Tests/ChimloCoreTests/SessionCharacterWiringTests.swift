import Foundation
import Testing

/// The character feature's app half lives in the app target, which has no
/// tests of its own, so this reads its source (as `CompanionEnvironmentTests`
/// does). It pins the rules that are easy to break by adding a new place a
/// session is drawn or a new setting: one view decides what a session shows,
/// the Claude logo is the default, automatic assignment is something the
/// owner turns on, and picking by hand works either way.
@Suite("Session characters: app wiring")
struct SessionCharacterWiringTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    private static func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    private static func body(of signature: String, in text: String) throws -> String {
        let start = try #require(text.range(of: signature), "\(signature) is missing")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    @Test("Every mark that stands for a session is drawn through SessionMark")
    func sessionMarksUseOneView() throws {
        let views = try Self.source("IslandViews.swift")
        // The closed notch (two layouts), the session row.
        #expect(views.components(separatedBy: "SessionMark(").count - 1 == 3)
        #expect(views.components(separatedBy: "character: model.activeCharacter").count - 1 == 2)
        // No session's mood is ever handed straight to the Claude mark.
        #expect(!views.contains("ClaudeCodeMark(\n                mood: model.activeMood"))
        #expect(!views.contains("ClaudeCodeMark(\n                mood: session.mood"))
        #expect(!views.contains("ClaudeCodeMark(mood: session.mood"))

        let inspector = try Self.source("IslandSessionInspector.swift")
        #expect(inspector.contains("SessionMark(character: character, mood: session.mood"))
        #expect(!inspector.contains("ClaudeCodeMark("))

        // The companion's session list shows the same mark, once any
        // session has a character.
        let pages = try Self.source("CompanionPages.swift")
        #expect(pages.contains("SessionMark(character: model.character(for: session)"))
        #expect(pages.contains("if model.anySessionWearsCharacter {"))
    }

    @Test("SessionMark falls back to the Claude mark when a session has no character")
    func fallback() throws {
        let marks = try Self.source("SessionCharacterViews.swift")
        let start = try #require(marks.range(of: "struct SessionMark: View {"))
        let end = try #require(marks.range(of: "struct CharacterSprite: View {"))
        let mark = String(marks[start.upperBound..<end.lowerBound])
        #expect(mark.contains("if let character {"))
        #expect(mark.contains("ClaudeCodeMark(mood: mood, size: size, reduceMotion: reduceMotion)"))
    }

    @Test("The Claude logo is the default: a session shows a character only once it has one to show")
    func claudeLogoIsTheDefault() throws {
        let model = try Self.source("ApplicationModel.swift")
        // Off until the settings say otherwise.
        #expect(model.contains("@Published private(set) var assignsCharactersAutomatically = false"))

        let lookup = try Self.body(of: "func character(for session: SessionDisplayModel) -> SessionCharacter? {", in: model)
        #expect(lookup.contains("characterAssignments.shownCharacter(for: session.id, automatic: assignsCharactersAutomatically)"))

        // Assignment always passes the owner's setting on; the core hands
        // nothing out while it is off. In the default state it does nothing.
        let assign = try Self.body(of: "private func assignCharacters() {", in: model)
        #expect(assign.contains("guard assignsCharactersAutomatically || !characterAssignments.bySession.isEmpty else { return }"))
        #expect(assign.contains("automatic: assignsCharactersAutomatically"))
        #expect(assign.contains("sessions: characterSessions"))
        #expect(assign.contains("pools: projectCharacterPools"))
        #expect(assign.contains("if changed { saveCharacterAssignments() }"))
        #expect(model.contains("sessions.map { CharacterSession(id: $0.id, projectPath: $0.projectPath) }"))
    }

    @Test("Picking by hand works whatever the automatic setting, and is saved")
    func manualPickNeedsNoSetting() throws {
        let model = try Self.source("ApplicationModel.swift")
        // Every session, but never behind a card that is waiting on the
        // owner.
        let allowed = try Self.body(of: "func canPickCharacter(for session: SessionDisplayModel) -> Bool {", in: model)
        #expect(allowed.trimmingCharacters(in: .whitespacesAndNewlines) == "!hasActiveOwnerInteraction")

        let picker = try Self.body(of: "var characterPickerSession: SessionDisplayModel? {", in: model)
        #expect(!picker.contains("assignsCharactersAutomatically"))
        #expect(picker.contains("!hasActiveOwnerInteraction"))

        for action in ["func chooseCharacter(", "func useClaudeLogo(", "func shuffleCharacter("] {
            let body = try Self.body(of: action, in: model)
            #expect(!body.contains("guard assignsCharactersAutomatically"), "\(action) must not depend on the setting")
            #expect(body.contains("saveCharacterAssignments()"), "\(action)")
            // A click counts only for the picker that is open, once it has
            // been up long enough to be read.
            #expect(body.contains("guard acceptsPickerClick(for: sessionID)"), "\(action)")
        }
        let accepts = try Self.body(of: "private func acceptsPickerClick(for sessionID: String) -> Bool {", in: model)
        #expect(accepts.contains("characterPickerSessionID == sessionID"))
        #expect(accepts.contains("Self.uptime >= characterPickerArmedAt"))
        #expect(accepts.contains("sessions.contains(where: { $0.id == sessionID })"))
        let open = try Self.body(of: "func openCharacterPicker(for session: SessionDisplayModel) {", in: model)
        #expect(open.contains("characterPickerArmedAt = Self.uptime + OwnerClickGuard.armingDelay"))
    }

    @Test("The closed notch's mark, mood, activity line and wing all speak for one session")
    func oneClosedNotchSession() throws {
        let model = try Self.source("ApplicationModel.swift")
        let mood = try Self.body(of: "var activeMood: AvatarMood {", in: model)
        #expect(mood.contains("closedNotchSession?.mood"))
        let character = try Self.body(of: "var activeCharacter: SessionCharacter? {", in: model)
        #expect(character.contains("closedNotchSession.flatMap(character(for:))"))
        let line = try Self.body(of: "private func currentCompactActivityLine() -> CompactActivityLine? {", in: model)
        #expect(line.contains("guard let session = notchFocusSession"))
        let focus = try Self.body(of: "private func refreshNotchFocus() {", in: model)
        #expect(focus.contains("current: notchFocusSessionID"))
        #expect(try Self.source("SessionInsightViews.swift").contains("let session = model.notchFocusSession"))
    }

    @Test("Characters are looked at whenever the session list is rebuilt, and when the setting changes")
    func assignedOnEveryRefresh() throws {
        let model = try Self.source("ApplicationModel.swift")
        let rebuilt = try #require(model.range(of: "sessions = SessionOrdering.ordered("))
        let assigned = try #require(model.range(of: "        assignCharacters()\n        noteCardLayout()"))
        #expect(rebuilt.lowerBound < assigned.lowerBound)

        // Loaded at launch, so a session keeps its character across restarts.
        #expect(model.contains("characterAssignments = CharacterAssignmentStore(defaults: defaults).load()"))

        let settings = try Self.body(of: "func applySettings(_ settings: OverheadSettings, now: Date = .now) {", in: model)
        #expect(settings.contains("assignsCharactersAutomatically = settings.assignCharactersAutomatically"))
        #expect(settings.contains("assignCharacters()"))
        #expect(settings.contains("projectCharacterPools = settings.projectCharacterPools"))
    }

    @Test("No trace is left of the first design, where characters were on by default")
    func noLeftovers() throws {
        let root = Self.appSources.deletingLastPathComponent()
        for folder in ["ChimloApp", "ChimloCore", "ChimloCLI", "ChimloProtocol"] {
            let directory = root.appendingPathComponent(folder)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for leftover in ["characterMode", "CharacterMode", "Default Mode", ".claudeLogo", "disableCharacter"] {
                    #expect(!text.contains(leftover), "\(file.lastPathComponent) still mentions \(leftover)")
                }
            }
        }
    }

    @Test("The picker opens from the mark, takes the panel, and closes with its session or the notch")
    func picker() throws {
        let model = try Self.source("ApplicationModel.swift")
        #expect(model.contains("case .sessions where characterPickerSession != nil || inspectedSession != nil:"))
        #expect(model.contains("if let characterPickerSessionID, byID[characterPickerSessionID] == nil {"))
        // Leaving the session list (closing, an update notice), opening the
        // activity feed, the session going away, and the back button each
        // close the picker.
        #expect(model.components(separatedBy: "characterPickerSessionID = nil").count - 1 == 4)
        #expect(model.contains("if oldValue == .sessions, panelMode != .sessions {"))

        let views = try Self.source("IslandViews.swift")
        #expect(views.contains("if let picking = model.characterPickerSession {"))
        #expect(views.contains("onPickCharacter: model.canPickCharacter(for: session)"))
        #expect(views.contains(".anchorPreference(key: CharacterMarkAnchorKey.self, value: .bounds) { $0 }"))
        #expect(views.contains("characterOverlay(anchor)"))
        // The usage panel never covers the picker.
        #expect(views.contains("&& model.characterPickerSession == nil"))

        let marks = try Self.source("SessionCharacterViews.swift")
        for world in ["CharacterWorld.allCases", "useClaudeLogo", "shuffle", "choose(character)"] {
            #expect(marks.contains(world), "\(world)")
        }
    }

    @Test("Settings has the automatic switch and project collections; the Projects page edits a project's own")
    func settingsScreens() throws {
        let settings = try Self.source("CompanionSettings.swift")
        #expect(settings.contains("CharacterSettingsSection()"))

        let characters = try Self.source("CompanionCharacters.swift")
        #expect(characters.contains(
            #"Toggle("Give sessions a character automatically", isOn: settings.binding(\.assignCharactersAutomatically))"#
        ))
        #expect(characters.contains("settings.projectCharacterPools.removeValue(forKey: key)"))
        #expect(characters.contains(#"Button("Add a Project…")"#))
        #expect(characters.contains(#"Button("Remove")"#))

        let pages = try Self.source("CompanionPages.swift")
        #expect(pages.contains("ProjectCharactersCard(pulse: pulse)"))
    }
}
