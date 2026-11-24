import AppKit
import ChimloCore
import SwiftUI

/// A character on the dark tile it was drawn for. The characters are made
/// for the notch's black, so the tile stays dark in a light theme too.
struct CharacterTile: View {
    let character: SessionCharacter
    var size: CGFloat = 34

    var body: some View {
        CharacterSprite(character: character, mood: .success, size: size, reduceMotion: true)
            .padding(4)
            .background(Color(white: 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(character.name)
    }
}

/// The project whose collection is being edited.
struct CharacterPoolTarget: Identifiable, Equatable {
    /// The project key the pool is stored under.
    let key: String
    var id: String { key }
    var name: String { ProjectKey.displayName(key) }
}

extension SettingsModel {
    /// The project's approved characters this version knows, in catalogue
    /// order; empty when the project uses the whole collection.
    func characterPool(forProject key: String) -> [SessionCharacter] {
        let ids = Set(CharacterCatalog.knownIDs(in: settings.projectCharacterPools[key] ?? []))
        return CharacterCatalog.all.filter { ids.contains($0.id) }
    }

    /// Stores a project's collection. An empty one removes the entry, which
    /// is what "use the whole collection" means.
    func setCharacterPool(_ ids: [String], forProject key: String) {
        let ordered = CharacterCatalog.all.map(\.id).filter(Set(ids).contains)
        if ordered.isEmpty {
            settings.projectCharacterPools.removeValue(forKey: key)
        } else {
            settings.projectCharacterPools[key] = ordered
        }
    }
}

/// Picks the characters one project's sessions may be given: every
/// character, grouped by world, each a toggle.
struct CharacterPoolEditor: View {
    let target: CharacterPoolTarget
    let save: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 8)]

    init(target: CharacterPoolTarget, initial: [String], save: @escaping ([String]) -> Void) {
        self.target = target
        self.save = save
        _selected = State(initialValue: Set(CharacterCatalog.knownIDs(in: initial)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Characters for \(target.name)")
                    .font(.title3.weight(.semibold))
                Text("With automatic characters on, a new session in this project gets a random one of the characters you pick. Sessions already running keep what they show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(CharacterWorld.allCases, id: \.self) { world in
                        worldSection(world)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 10) {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use the Whole Collection") {
                    save([])
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .help("Removes this project's own collection")
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    save(Array(selected))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 660, height: 580)
    }

    private var summary: String {
        switch selected.count {
        case 0: "Nothing picked: this project uses the whole collection."
        case 1: "1 character picked. Every new session in this project is given it."
        default: "\(selected.count) characters picked."
        }
    }

    private func worldSection(_ world: CharacterWorld) -> some View {
        let characters = CharacterCatalog.characters(in: world)
        let ids = Set(characters.map(\.id))
        let picked = selected.intersection(ids).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(world.displayName).font(.headline)
                Text("\(picked) of \(characters.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All") { selected.formUnion(ids) }
                    .disabled(picked == characters.count)
                    .accessibilityLabel("Pick all of \(world.displayName)")
                Button("None") { selected.subtract(ids) }
                    .disabled(picked == 0)
                    .accessibilityLabel("Pick none of \(world.displayName)")
            }
            .controlSize(.small)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(characters) { character in
                    CharacterPoolCell(
                        character: character,
                        isSelected: selected.contains(character.id),
                        toggle: {
                            if !selected.insert(character.id).inserted { selected.remove(character.id) }
                        }
                    )
                }
            }
        }
    }
}

private struct CharacterPoolCell: View {
    let character: SessionCharacter
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 4) {
                CharacterTile(character: character, size: 40)
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 5, y: -5)
                        }
                    }
                Text(character.name)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(character.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A short row of a collection's characters, with "+N" for the rest.
struct CharacterPoolStrip: View {
    let characters: [SessionCharacter]
    var limit = 8
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 4) {
            ForEach(characters.prefix(limit)) { character in
                CharacterTile(character: character, size: size)
                    .help(character.name)
            }
            if characters.count > limit {
                Text("+\(characters.count - limit)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// On the Projects page: which characters the selected project's sessions
/// may be given, and the button to choose them.
struct ProjectCharactersCard: View {
    let pulse: ProjectPulse
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.overheadPalette) private var palette
    @State private var editing: CharacterPoolTarget?

    private var key: String? { ProjectKey.make(pulse.path) }

    var body: some View {
        Card("Characters · \(pulse.name)") {
            if let key {
                let pool = settings.characterPool(forProject: key)
                VStack(alignment: .leading, spacing: 10) {
                    if pool.isEmpty {
                        Text("This project has no collection of its own: automatic characters draw from all \(CharacterCatalog.all.count).")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    } else {
                        Text(pool.count == 1
                            ? "Automatic characters give every new session in this project this one."
                            : "Automatic characters give a new session in this project a random one of these \(pool.count).")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                        CharacterPoolStrip(characters: pool, limit: 14, size: 26)
                    }
                    if !settings.settings.assignCharactersAutomatically {
                        Text("Automatic characters are off, so sessions show the Claude logo until you pick a character in the notch. Turn them on in Settings › Appearance to use this collection.")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textTertiary)
                    }
                    HStack(spacing: 8) {
                        Button(pool.isEmpty ? "Choose Characters…" : "Change Characters…") {
                            editing = CharacterPoolTarget(key: key)
                        }
                        if !pool.isEmpty {
                            Button("Use the Whole Collection") {
                                settings.setCharacterPool([], forProject: key)
                            }
                        }
                    }
                }
            } else {
                Text("This project's folder is not known, so its sessions draw from the whole collection.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .sheet(item: $editing) { target in
            CharacterPoolEditor(
                target: target,
                initial: settings.settings.projectCharacterPools[target.key] ?? [],
                save: { settings.setCharacterPool($0, forProject: target.key) }
            )
        }
    }
}

/// Settings › Appearance › Characters & Mascots: every character the app
/// ships, drawn from its real artwork and browsable by world; the session to
/// dress; the automatic switch (off by default); and each project's own
/// collection, including projects whose folders are gone.
///
/// This is a second door to the same room, not a second room: a choice made
/// here goes through the model to the assignments the notch's picker
/// writes, so either place shows what the other chose.
struct CharacterSettingsSection: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var model: ApplicationModel
    @Environment(\.overheadPalette) private var palette
    @State private var editing: CharacterPoolTarget?

    private var isAutomatic: Bool { settings.settings.assignCharactersAutomatically }

    private var projectKeys: [String] {
        settings.settings.projectCharacterPools.keys.sorted {
            ProjectKey.displayName($0).localizedCaseInsensitiveCompare(ProjectKey.displayName($1)) == .orderedAscending
        }
    }

    var body: some View {
        SettingsSection(
            .characters,
            "Characters & Mascots",
            info: "A session can wear a character in place of the Claude logo, so several sessions are easy to tell apart. Choose one here, or click a session's logo in the notch: both set the same thing. A character you choose stays on that session until it ends, whatever the automatic setting.",
            accessory: {
                Text("\(CharacterCatalog.all.count) characters · \(CharacterWorld.allCases.count) worlds")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                CharacterGallery(
                    sessions: model.sessions.map { session in
                        CharacterGallery.Session(
                            id: session.id,
                            title: session.displayTitle,
                            worn: model.character(for: session)
                        )
                    },
                    reduceMotion: model.reducesMotion,
                    apply: { character, sessionID in model.setCharacterFromSettings(character, for: sessionID) }
                )
                SettingsGroup {
                    Toggle("Give sessions a character automatically", isOn: settings.binding(\.assignCharactersAutomatically))
                    SettingsRow("Sessions show") {
                        Text(isAutomatic ? "A random character each" : "The Claude logo, unless you choose one")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsNote(isAutomatic
                    ? "Every session without a character gets a random one, different from the other open sessions where it can. A character you choose always wins. Turning this off brings the Claude logo back and keeps your own choices."
                    : "Off by default: every session shows the Claude logo until you give it a character, here or in the notch.")
                projectCollections
            }
        }
    }

    // MARK: Project collections

    private var projectCollections: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Project collections")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                SettingsInfoButton(
                    text: isAutomatic
                        ? "A project with its own collection gives new sessions a random character from that collection only. Changing a collection never changes a character a running session already wears."
                        : "Collections are what automatic characters draw from once that is on. Until then they only narrow “Surprise me” in the notch; you can always choose any character for a session yourself.",
                    about: "Project collections"
                )
            }
            .padding(.horizontal, 2)
            SettingsGroup {
                if projectKeys.isEmpty {
                    Text("No project has its own collection. Automatic characters draw from all \(CharacterCatalog.all.count) for every project.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                for key in projectKeys {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ProjectKey.displayName(key)).font(.system(size: 13))
                            Text(key)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        CharacterPoolStrip(characters: settings.characterPool(forProject: key), limit: 6)
                        Button("Edit…") { editing = CharacterPoolTarget(key: key) }
                        Button("Remove") { settings.setCharacterPool([], forProject: key) }
                            .help("This project goes back to the whole collection")
                    }
                    .controlSize(.small)
                }
                SettingsRow("Give a project its own characters") {
                    Button("Add a Project…") { chooseProjectFolder() }
                        // One presenter, on one view: a sheet attached to the whole
                        // section could be offered by every row.
                        .sheet(item: $editing) { target in
                            CharacterPoolEditor(
                                target: target,
                                initial: settings.settings.projectCharacterPools[target.key] ?? [],
                                save: { settings.setCharacterPool($0, forProject: target.key) }
                            )
                        }
                }
            }
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder whose sessions should use their own characters."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Claude Code reports a session's folder by its real path, so a
        // folder reached through a symbolic link is stored the same way.
        let path = realpath(url.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? url.path
        guard let key = ProjectKey.make(path) else { return }
        editing = CharacterPoolTarget(key: key)
    }
}

/// Every character the app ships, drawn from its real artwork: a large
/// preview, the sessions that can be dressed, the worlds to browse, and a
/// tile for each character with the Claude logo first.
///
/// It takes the sessions as values and reports a choice through `apply`, so
/// it holds no character state of its own and can be drawn without the app.
struct CharacterGallery: View {
    /// An open session as the gallery needs it.
    struct Session: Identifiable, Equatable {
        let id: String
        let title: String
        /// Its character, or nil for the Claude logo.
        let worn: SessionCharacter?
    }

    let sessions: [Session]
    let reduceMotion: Bool
    /// A character (or nil for the Claude logo) chosen for a session id.
    let apply: (SessionCharacter?, String) -> Void

    @Environment(\.overheadPalette) private var palette
    /// The world being browsed; nil is every world.
    @State private var world: CharacterWorld?
    /// The session being dressed, when the owner picked one of several.
    @State private var targetID: String?
    /// What the large preview shows; nil follows what the session wears.
    @State private var previewed: GalleryChoice?
    @State private var hovered: String?

    private var target: Session? {
        sessions.first { $0.id == targetID } ?? sessions.first
    }

    /// What the session being dressed wears now.
    private var worn: GalleryChoice? {
        target.map { $0.worn.map(GalleryChoice.character) ?? .logo }
    }

    private var shown: GalleryChoice { previewed ?? worn ?? .logo }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                preview
                sessionStrip
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("World", selection: $world) {
                Text("All \(CharacterCatalog.all.count)").tag(CharacterWorld?.none)
                ForEach(CharacterWorld.allCases, id: \.self) { world in
                    Text("\(world.displayName) \(CharacterCatalog.characters(in: world).count)")
                        .tag(CharacterWorld?.some(world))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            .accessibilityLabel("Collection")
            ForEach(CharacterWorld.allCases.filter { world == nil || world == $0 }, id: \.self) { world in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(world.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                        Text("\(CharacterCatalog.characters(in: world).count)")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                        if world == CharacterWorld.allCases.first {
                            tile(.logo)
                        }
                        ForEach(CharacterCatalog.characters(in: world)) { character in
                            tile(.character(character))
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.groupRadius, style: .continuous)
                .strokeBorder(palette.hairlineColor, lineWidth: 1)
        )
    }

    /// The character being looked at, large, with the button that gives it
    /// to the session.
    private var preview: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                switch shown {
                case .logo:
                    ClaudeCodeMark(mood: .idle, size: 54, reduceMotion: true)
                case let .character(character):
                    CharacterSprite(character: character, mood: .working, size: 64, reduceMotion: reduceMotion)
                }
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(shown.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(shown.caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 2)
                if let target {
                    if shown == worn {
                        Label("\(target.title) wears this", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.success)
                            .lineLimit(1)
                    } else {
                        Button(shown == .logo ? "Use the Claude Logo" : "Use for \(target.title)") {
                            apply(shown, to: target)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .lineLimit(1)
                    }
                } else {
                    Text("Open a Claude session to dress it")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textTertiary)
                }
            }
            .frame(width: 190, height: 96, alignment: .leading)
        }
    }

    /// The open sessions, each with what it wears. Characters belong to a
    /// session, so the gallery asks which one to dress.
    @ViewBuilder
    private var sessionStrip: some View {
        if sessions.isEmpty {
            Text("No Claude session is open. A character is worn by one session: start one, then choose here or click its logo in the notch.")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Dress a session")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sessions) { session in
                            let isTarget = session.id == target?.id
                            Button {
                                targetID = session.id
                                previewed = nil
                            } label: {
                                HStack(spacing: 6) {
                                    SessionMark(character: session.worn, mood: .idle, size: 16, reduceMotion: true)
                                        .padding(3)
                                        .background(Color.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    Text(session.title)
                                        .font(.system(size: 12, weight: isTarget ? .semibold : .regular))
                                        .lineLimit(1)
                                        .frame(maxWidth: 150)
                                        .fixedSize()
                                }
                                .padding(.leading, 4)
                                .padding(.trailing, 9)
                                .frame(height: 28)
                                .background(isTarget ? palette.accentColor.opacity(0.14) : palette.raisedColor)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(isTarget ? palette.accentColor : Color.clear, lineWidth: 1.5))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dress \(session.title)")
                            .accessibilityAddTraits(isTarget ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private func tile(_ choice: GalleryChoice) -> some View {
        let isWorn = choice == worn
        let isShown = choice == shown
        return Button {
            previewed = choice
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.07))
                    switch choice {
                    case .logo:
                        ClaudeCodeMark(mood: .idle, size: 30, reduceMotion: true)
                    case let .character(character):
                        CharacterSprite(
                            character: character,
                            mood: hovered == choice.id ? .waiting : .idle,
                            size: 36,
                            reduceMotion: reduceMotion
                        )
                    }
                }
                .frame(height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isWorn ? palette.accentColor : (isShown ? palette.textSecondary : Color.clear),
                            lineWidth: isWorn ? 2 : 1.5
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if isWorn {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accentColor)
                            .background(Circle().fill(Color.black).padding(1))
                            .padding(4)
                    }
                }
                .scaleEffect(hovered == choice.id ? 1.04 : 1)
                Text(choice.name)
                    .font(.system(size: 10.5, weight: isWorn ? .semibold : .regular))
                    .foregroundStyle(isWorn || isShown ? palette.textPrimary : palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = choice.id } else if hovered == choice.id { hovered = nil }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .help(choice.name)
        .accessibilityLabel("\(choice.name), \(choice.caption)")
        .accessibilityHint("Shows it larger")
        .accessibilityAddTraits(isWorn ? .isSelected : [])
    }

    private func apply(_ choice: GalleryChoice, to session: Session) {
        switch choice {
        case .logo: apply(nil, session.id)
        case let .character(character): apply(character, session.id)
        }
        previewed = nil
    }
}

/// One thing a session can wear, as the gallery lists it: the Claude logo,
/// which is the default, or a character.
private enum GalleryChoice: Equatable {
    case logo
    case character(SessionCharacter)

    var id: String {
        switch self {
        case .logo: "claude-logo"
        case let .character(character): character.id
        }
    }

    var name: String {
        switch self {
        case .logo: "Claude logo"
        case let .character(character): character.name
        }
    }

    var caption: String {
        switch self {
        case .logo: "The default for every session"
        case let .character(character): character.world.displayName
        }
    }
}
