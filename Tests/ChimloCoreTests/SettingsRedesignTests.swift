import Foundation
import Testing
@testable import ChimloCore

// MARK: - Search

@Suite("Settings search")
struct SettingsCatalogTests {
    @Test("Every pane and every group of controls can be found")
    func coverage() {
        let entries = SettingsCatalog.entries
        #expect(Set(entries.map(\.id)).count == entries.count)
        for pane in SettingsPaneID.allCases {
            #expect(entries.contains { $0.pane == pane }, "\(pane) has no entry")
        }
        for anchor in SettingsAnchor.allCases {
            #expect(entries.contains { $0.anchor == anchor }, "\(anchor) has no entry")
        }
        for entry in entries {
            #expect(!entry.title.isEmpty && !entry.summary.isEmpty)
            #expect(entry.summary.count <= 90, "\(entry.id) says too much")
            #expect(entry.pane == entry.anchor.pane)
        }
    }

    @Test("The panes are the seven, with sound and notifications as one")
    func panes() {
        #expect(SettingsPaneID.allCases.map(\.displayName) == [
            "General", "Appearance", "Notifications & Sound", "Usage", "Shortcuts", "GitHub", "Privacy",
        ])
        // The saved names are what other code and old links use; they did not change.
        #expect(SettingsPaneID.allCases.map(\.rawValue) == [
            "general", "appearance", "notifications", "usage", "shortcuts", "github", "privacy",
        ])
    }

    @Test(
        "What people type lands on the right group",
        arguments: [
            ("Glow", SettingsAnchor.glow),
            ("RGB", .glow),
            ("Volume", .sound),
            ("Sound", .sound),
            ("Startup", .startup),
            ("Lock Mode", .behaviour),
            ("Repository", .repositories),
            ("Quiet hours", .quietHours),
            ("Context threshold", .context),
            ("Shortcut", .shortcuts),
            ("History retention", .history),
            ("Characters", .characters),
            ("Mascots", .characters),
            ("Automatic character assignment", .characters),
            ("Character collections", .characters),
            ("theme", .theme),
            ("login", .startup),
            ("merge", .monitoring),
            ("token", .githubConnection),
            ("delete history", .yourData),
            ("telemetry", .network),
            ("reduce motion", .accessibility),
            ("update", .updates),
            ("focus", .focus),
        ]
    )
    func lands(query: String, anchor: SettingsAnchor) throws {
        let first = try #require(SettingsCatalog.search(query).first, "nothing for \(query)")
        #expect(first.anchor == anchor, "\(query) landed on \(first.title)")
    }

    @Test("A result names its setting, its pane and one line about it")
    func resultContent() throws {
        let entry = try #require(SettingsCatalog.search("Automatic character assignment").first)
        #expect(entry.title == "Automatic character assignment")
        #expect(entry.pane.displayName == "Appearance")
        #expect(!entry.summary.isEmpty)
        #expect(SettingsCatalog.search("Character collections").first?.title == "Character collections")
        #expect(SettingsCatalog.search("Lock Mode").first?.title == "Lock Mode")
    }

    @Test("Search is plain and repeatable: same words, same list")
    func deterministic() {
        for query in ["glow", "sound", "github", "history", "s", "notch"] {
            #expect(SettingsCatalog.search(query) == SettingsCatalog.search(query))
            #expect(SettingsCatalog.search(query.uppercased()) == SettingsCatalog.search(query))
            #expect(SettingsCatalog.search("  \(query)  ") == SettingsCatalog.search(query))
        }
        #expect(SettingsCatalog.search("").isEmpty)
        #expect(SettingsCatalog.search("   ").isEmpty)
        #expect(SettingsCatalog.search("zzzz").isEmpty)
        #expect(SettingsCatalog.search("a", limit: 3).count <= 3)
        #expect(SettingsCatalog.search("sound", limit: 0).isEmpty)
    }

    @Test("Every word typed must match")
    func allWords() {
        #expect(SettingsCatalog.search("glow volume").isEmpty)
        let both = SettingsCatalog.search("context critical")
        #expect(both.first?.id == "contextCritical")
        #expect(both.allSatisfy { $0.anchor == .context })
    }

    @Test("Anything typed is safe to search for")
    func oddInput() {
        let odd = [
            String(repeating: "glow ", count: 2_000), String(repeating: "x", count: 50_000),
            "\\.*+?[]()^$|", "🙂✨", "\u{0}\u{1}", "   \n\t  ", "’“”", "GLOW\nvolume", "ｇｌｏｗ",
        ]
        for query in odd {
            let results = SettingsCatalog.search(query)
            #expect(results.count <= 12)
            #expect(Set(results.map(\.id)).count == results.count)
        }
        #expect(SettingsCatalog.search("glow", limit: -5).isEmpty)
    }

    @Test("Each shortcut action can be found by its name")
    func shortcutActions() {
        for action in ShortcutAction.allCases {
            #expect(SettingsCatalog.search(action.displayName).contains { $0.anchor == .shortcuts }, "\(action)")
        }
    }
}

// MARK: - Repositories by owner

@Suite("GitHub repository picker: owners")
struct GitHubOwnerGroupTests {
    private let mine = GitHubRepoRef(id: 1, owner: "octo-dev", name: "website", isPrivate: true)
    private let tools = GitHubRepoRef(id: 2, owner: "octo-dev", name: "notch-tools", isPrivate: false)
    private let theirs = GitHubRepoRef(id: 11, owner: "acme-labs", name: "website", isPrivate: true)
    private let billing = GitHubRepoRef(id: 12, owner: "acme-labs", name: "billing", isPrivate: true)
    private let other = GitHubRepoRef(id: 21, owner: "Northwind", name: "inventory", isPrivate: nil)

    private var all: [GitHubRepoRef] { [theirs, other, mine, billing, tools] }

    @Test("Repositories are grouped by their GitHub owner, the viewer's own first")
    func groups() {
        let groups = GitHubRepoSearch.ownerGroups(all, selection: GitHubRepositorySelection(), viewer: "octo-dev")
        #expect(groups.map(\.owner) == ["octo-dev", "acme-labs", "Northwind"])
        #expect(groups[0].repositories.map(\.name) == ["notch-tools", "website"])
        #expect(groups[1].repositories.map(\.name) == ["billing", "website"])
        #expect(groups.allSatisfy { $0.selectedCount == 0 && !$0.isFullySelected })
    }

    @Test("Two repositories with one name under different owners stay two rows")
    func sameNameDifferentOwners() {
        var selection = GitHubRepositorySelection()
        selection.select(mine)
        let groups = GitHubRepoSearch.ownerGroups(all, selection: selection, viewer: "octo-dev")
        let rows = groups.flatMap(\.repositories).filter { $0.name == "website" }
        #expect(rows.map(\.id) == [1, 11])
        // Selecting one does not select the other: selection is by GitHub's id.
        #expect(selection.contains(1) && !selection.contains(11))
        #expect(groups.first { $0.owner == "octo-dev" }?.selectedCount == 1)
        #expect(groups.first { $0.owner == "acme-labs" }?.selectedCount == 0)
    }

    @Test("Each owner says how many of its repositories are selected")
    func counts() {
        var selection = GitHubRepositorySelection()
        selection.select(all: [mine, tools, theirs])
        let groups = GitHubRepoSearch.ownerGroups(all, selection: selection, viewer: nil)
        let byOwner = Dictionary(uniqueKeysWithValues: groups.map { ($0.owner, $0) })
        #expect(byOwner["octo-dev"]?.selectedCount == 2)
        #expect(byOwner["octo-dev"]?.isFullySelected == true)
        #expect(byOwner["acme-labs"]?.selectedCount == 1)
        #expect(byOwner["acme-labs"]?.isFullySelected == false)
        #expect(byOwner["Northwind"]?.selectedCount == 0)
        #expect(groups.map(\.selectedCount).reduce(0, +) == selection.count)
    }

    @Test("Selecting or clearing one owner leaves the others as they were")
    func ownerLevelActions() {
        var selection = GitHubRepositorySelection()
        selection.select(theirs)
        let octo = GitHubRepoSearch.ownerGroups(all, selection: selection, viewer: nil).first { $0.owner == "octo-dev" }
        selection.select(all: octo?.repositories ?? [])
        #expect(Set(selection.ids) == [1, 2, 11])
        selection.deselect(all: octo?.repositories ?? [])
        #expect(selection.ids == [11])
    }

    @Test("Searching keeps owners and their counts, and finds an owner by name")
    func search() {
        var selection = GitHubRepositorySelection()
        selection.select(all: [mine, theirs])
        let matches = GitHubRepoSearch.filter(all, query: "website")
        let groups = GitHubRepoSearch.ownerGroups(matches, selection: selection, viewer: "octo-dev")
        #expect(groups.map(\.owner) == ["octo-dev", "acme-labs"])
        #expect(groups.map(\.selectedCount) == [1, 1])
        let byOwner = GitHubRepoSearch.filter(all, query: "ACME")
        #expect(Set(byOwner.map(\.id)) == [11, 12])
    }

    @Test("Groups holding a selection start open, and so does the viewer's own")
    func initiallyOpen() {
        var selection = GitHubRepositorySelection()
        selection.select(billing)
        let groups = GitHubRepoSearch.ownerGroups(all, selection: selection, viewer: "octo-dev")
        #expect(GitHubRepoSearch.initiallyExpandedOwners(groups, viewer: "octo-dev") == ["octo-dev", "acme-labs"])
        #expect(GitHubRepoSearch.initiallyExpandedOwners(groups, viewer: nil) == ["acme-labs"])
        let none = GitHubRepoSearch.ownerGroups(all, selection: GitHubRepositorySelection(), viewer: nil)
        #expect(GitHubRepoSearch.initiallyExpandedOwners(none, viewer: nil).count == 1)
        #expect(GitHubRepoSearch.initiallyExpandedOwners([], viewer: nil).isEmpty)
    }

    @Test("Thousands of repositories under hundreds of owners group correctly and in step with their number")
    func largeLists() {
        func repositories(_ count: Int) -> [GitHubRepoRef] {
            (0..<count).map { GitHubRepoRef(id: Int64($0), owner: "owner-\($0 % 250)", name: "repo-\($0)", isPrivate: $0 % 2 == 0) }
        }
        let many = repositories(10_000)
        var selection = GitHubRepositorySelection()
        selection.select(all: Array(many.prefix(300)))
        let groups = GitHubRepoSearch.ownerGroups(many, selection: selection, viewer: "owner-7")
        #expect(groups.count == 250)
        #expect(groups.first?.owner == "owner-7")
        #expect(groups.map(\.repositories.count).reduce(0, +) == 10_000)
        #expect(groups.map(\.selectedCount).reduce(0, +) == 300)
        #expect(GitHubRepoSearch.filter(many, query: "repo-9999").map(\.id) == [9_999])

        let few = repositories(1_000)
        let cost = CostGrowth.measure(
            whole: { _ = GitHubRepoSearch.ownerGroups(many, selection: selection, viewer: nil) },
            tenth: { _ = GitHubRepoSearch.ownerGroups(few, selection: selection, viewer: nil) }
        )
        #expect(CostGrowth.isInStep(whole: cost.whole, tenth: cost.tenth), "\(cost)")
    }

    @Test("A selection made before the redesign reads back exactly, ids and all")
    func savedSelectionIsUntouched() throws {
        var selection = GitHubRepositorySelection()
        selection.select(all: [mine, theirs, other])
        selection.focus(11)
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(GitHubRepositorySelection.self, from: data)
        #expect(decoded == selection)
        #expect(decoded.ids == [1, 11, 21] || Set(decoded.ids) == [1, 11, 21])
        #expect(decoded.focusedID == 11)
        // Grouping is only a way of showing it: it changes nothing in it.
        _ = GitHubRepoSearch.ownerGroups(all, selection: decoded, viewer: "octo-dev")
        #expect(decoded == selection)
    }
}

// MARK: - The app's Settings sources

/// Settings is drawn by the app target, which has no tests of its own, so
/// this reads its source (as the other wiring suites do). It pins what the
/// redesign promised: one sidebar, no setting lost, no control in two places,
/// one character state, and no GitHub dashboard inside Settings.
@Suite("Settings redesign: app wiring")
struct SettingsRedesignWiringTests {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ChimloApp")

    private static func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    /// The files that hold Settings controls.
    private static let settingsFiles = ["CompanionSettings.swift", "CompanionCharacters.swift", "GitHubIntegration.swift"]

    private static func settingsSources() throws -> String {
        try settingsFiles.map(source).joined(separator: "\n")
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Settings takes over the one sidebar; there is no second one and no tab row")
    func oneSidebar() throws {
        let window = try Self.source("CompanionWindow.swift")
        #expect(Self.count("NavigationSplitView {", in: window) == 1)
        #expect(window.contains("if navigation.isInSettings {"))
        #expect(window.contains("SettingsSidebar(navigation: navigation)"))
        #expect(window.contains("ForEach(SettingsPane.allCases) { pane in"))
        // Back returns to the page Settings was opened from.
        #expect(window.contains("Button { navigation.leaveSettings() } label: {"))
        #expect(window.contains("section = workspaceSection"))
        #expect(window.contains(".keyboardShortcut(\"[\", modifiers: .command)"))
        // The panes are not listed a second time above the content.
        let settings = try Self.source("CompanionSettings.swift")
        #expect(!settings.contains("ForEach(SettingsPane.allCases)"))
        #expect(settings.contains("SettingsSearchField("))
        #expect(settings.contains("SettingsCatalog.search(query)"))
        #expect(settings.contains("navigation.showSettings(at: entry.anchor)"))
    }

    @Test("Every group search can land on is on a pane")
    func everyAnchorIsDrawn() throws {
        let sources = try Self.settingsSources()
        for anchor in SettingsAnchor.allCases {
            #expect(sources.contains(".\(anchor.rawValue),"), "no section for \(anchor)")
        }
    }

    @Test("No setting was lost: every preference still has its control")
    func everySettingHasAControl() throws {
        let sources = try Self.settingsSources()
        let bound = [
            "launchAtLogin", "preferredDisplay", "notchLocked", "notchHidden", "askAboutUnattendedRuns",
            "accent", "animationIntensity", "density", "sessionSort", "groupByProject", "dailyRecapEnabled",
            "showAgents", "showClosedNotchActivity", "assignCharactersAutomatically",
            "storeConversationPreviews", "historyRetentionDays",
            "showResetCountdowns", "showCacheMetrics", "shortcutsEnabled",
            "notifications.soundsEnabled", "notifications.soundChoice", "notifications.soundVolume",
            "notifications.groupCompletions", "notifications.quietHoursEnabled",
            "focus.isOn", "focus.suppressInformational", "focus.muteSounds", "focus.reduceAnimations",
            "focus.hideActivityLabels", "focus.scheduleEnabled",
            "github.enabled", "github.trackPullRequests", "github.monitorActions", "github.reviewNotifications",
            "github.allowMerging", "github.fastRefreshWhileRunning", "github.refreshSeconds",
            "github.groupNotifications", "github.notchModeEnabled", "github.showNotchButton",
            "github.defaultView", "github.density", "github.showAccount", "github.showRepositoryInfo",
            "github.showDetailedMetadata", "github.showRunningIndicator", "github.showPullRequestIndicator",
            "github.showInClosedNotch",
        ]
        for keyPath in bound {
            #expect(sources.contains("settings.binding(\\.\(keyPath))"), "\(keyPath) has no control")
        }
        // The ones set through something other than a plain binding.
        for written in [
            "settings.settings.layout = candidate",
            #"threshold("Warn at", \.contextAttentionThreshold)"#,
            #"threshold("Critical at", \.contextCriticalThreshold)"#,
            #"threshold("Warn at", \.usageWarningThreshold)"#,
            "value: settings.binding(keyPath),",
            "settings.settings.theme = theme",
            "settings.settings.setCompletionGlowEnabled($0)",
            "settings.settings.completionGlowTheme = theme",
            "settings.settings.glowIntensity = $0",
            "settings.settings.notifications.quietHours = $0",
            "settings.settings.focus.schedule = $0",
            "settings.settings.notifications.perEvent[kind] = updated",
            "settings.settings.shortcuts[action] = combo",
            "settings.settings.shortcuts[action] = nil",
            "settings.settings.shortcuts = ShortcutDefaults.bindings",
            "settings.settings.github.selection = $0",
            "settings.settings.github.setAlertLevel(level, for: id)",
            "settings.setCharacterPool($0, forProject: target.key)",
            "settings.settings = OverheadSettings()",
        ] {
            #expect(sources.contains(written), "missing: \(written)")
        }
    }

    @Test("No control is drawn twice")
    func noDuplicateControls() throws {
        let sources = try Self.settingsSources()
        let pattern = try NSRegularExpression(pattern: #"settings\.binding\(\\\.([A-Za-z.]+)\)"#)
        let matches = pattern.matches(in: sources, range: NSRange(sources.startIndex..., in: sources))
        var seen: [String: Int] = [:]
        for match in matches {
            if let range = Range(match.range(at: 1), in: sources) { seen[String(sources[range]), default: 0] += 1 }
        }
        #expect(seen.count >= 45)
        for (keyPath, times) in seen {
            #expect(times == 1, "\(keyPath) is bound \(times) times")
        }
        // Whether a GitHub event shows is decided in the notifications
        // table, not a second time among GitHub's own switches.
        let github = try Self.source("GitHubIntegration.swift")
        #expect(!github.contains("perEvent"))
        #expect(github.contains("navigation.showSettings(at: .githubEvents)"))
    }

    @Test("Settings → GitHub configures GitHub and shows none of its activity")
    func noDashboardInSettings() throws {
        let github = try Self.source("GitHubIntegration.swift")
        for dashboard in [
            "GitHubPageTab", "PullRequestLine(", "RunLine(", "CIBadge(", "ReviewBadge(",
            "github.pullRequests", "github.runs", "github.reviewRequests", "todayCounts", "StatTile(",
        ] {
            #expect(!github.contains(dashboard), "Settings → GitHub shows \(dashboard)")
        }
        // The page that does show it is still there.
        let pages = try Self.source("CompanionPages.swift")
        #expect(pages.contains("case .github: GitHubPage()"))
        // Repositories are grouped by GitHub's owner and chosen by GitHub's id.
        #expect(github.contains("GitHubRepoSearch.ownerGroups(visible, selection: current, viewer: viewer)"))
        #expect(github.contains("edit { $0.toggle(ref) }"))
        #expect(github.contains("edit { $0.select(all: group.repositories) }"))
        #expect(github.contains("edit { $0.deselect(all: group.repositories) }"))
        #expect(github.contains("Button(\"Revert\") { draft = nil }.disabled(!hasChanges)"))
        #expect(github.contains("if let draft { apply(draft) }"))
    }

    @Test("The gallery and the notch's picker write one character state")
    func oneCharacterState() throws {
        let model = try Self.source("ApplicationModel.swift")
        let start = try #require(model.range(of: "func setCharacterFromSettings(_ character: SessionCharacter?, for sessionID: String) {"))
        let end = try #require(model[start.upperBound...].range(of: "\n    }\n"))
        let body = String(model[start.upperBound..<end.lowerBound])
        // The same assignments, saved the same way, as the picker's own functions.
        #expect(body.contains("characterAssignments.choose(character.id, for: sessionID, now: .now)"))
        #expect(body.contains("characterAssignments.useClaudeLogo("))
        #expect(body.contains("automatic: assignsCharactersAutomatically"))
        #expect(Self.count("saveCharacterAssignments()", in: body) == 2)
        #expect(body.contains("guard sessions.contains(where: { $0.id == sessionID }) else { return }"))
        // The picker is still there, unchanged, and nothing else stores characters.
        #expect(model.contains("func chooseCharacter(_ character: SessionCharacter, for sessionID: String) {"))
        #expect(model.contains("func openCharacterPicker(for session: SessionDisplayModel) {"))
        #expect(Self.count("CharacterAssignmentStore(defaults: defaults)", in: model) == 2)

        let characters = try Self.source("CompanionCharacters.swift")
        #expect(characters.contains("apply: { character, sessionID in model.setCharacterFromSettings(character, for: sessionID) }"))
        #expect(characters.contains("worn: model.character(for: session)"))
        // The gallery keeps no character state of its own.
        let galleryStart = try #require(characters.range(of: "struct CharacterGallery: View {"))
        let galleryEnd = try #require(characters.range(of: "private enum GalleryChoice: Equatable {"))
        let gallery = String(characters[galleryStart.upperBound..<galleryEnd.lowerBound])
        #expect(!gallery.contains("UserDefaults"))
        #expect(!gallery.contains("@EnvironmentObject"))
        #expect(!gallery.contains("characterAssignments"))
    }

    @Test("The gallery shows every shipped character, from its real artwork, by world")
    func galleryShowsTheRealCatalogue() throws {
        let characters = try Self.source("CompanionCharacters.swift")
        #expect(characters.contains("ForEach(CharacterWorld.allCases.filter { world == nil || world == $0 }, id: \\.self) { world in"))
        #expect(characters.contains("ForEach(CharacterCatalog.characters(in: world)) { character in"))
        #expect(characters.contains("CharacterSprite("))
        #expect(characters.contains("ClaudeCodeMark(mood: .idle"))
        #expect(characters.contains("tile(.logo)"))
        // No stand-in pictures.
        #expect(!characters.contains("Image(systemName: \"person"))
        #expect(!characters.contains("Text(\"🙂\")"))
        // And the catalogue it reads is the whole one.
        #expect(CharacterWorld.allCases.map { CharacterCatalog.characters(in: $0).count }.reduce(0, +) == CharacterCatalog.all.count)
        #expect(Set(CharacterCatalog.all.map(\.name)).count == CharacterCatalog.all.count)
    }

    @Test("Automatic characters are still off until turned on, and a choice still wins")
    func characterRulesUnchanged() {
        #expect(!OverheadSettings().assignCharactersAutomatically)
        var assignments = CharacterAssignments()
        let first = CharacterCatalog.all[0]
        assignments.choose(first.id, for: "s1", now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(assignments.shownCharacter(for: "s1", automatic: false) == first)
        #expect(assignments.shownCharacter(for: "s1", automatic: true) == first)
        // A session nobody dressed shows the Claude logo while automatic is off.
        #expect(assignments.shownCharacter(for: "s2", automatic: false) == nil)
    }

    @Test("Settings can be drawn to pictures without starting the app")
    func renderMode() throws {
        let render = try Self.source("SettingsPreviewRender.swift")
        #expect(render.contains("guard let flag = arguments.firstIndex(of: \"--render-settings\") else { return }"))
        #expect(render.contains("defer { defaults.removePersistentDomain(forName: suite) }"))
        #expect(render.contains("SettingsModel(store: SettingsStore(defaults: defaults))"))
        // It builds the services and never starts them.
        #expect(!render.contains(".start()"))
        let app = try Self.source("ChimloApp.swift")
        #expect(app.contains("SettingsRenderCheck.runIfRequested()"))
    }
}
