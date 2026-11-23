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

/// In Settings › Appearance: the automatic-characters switch (off by
/// default), and every project that has its own collection, including
/// projects whose folders are gone.
struct CharacterSettingsSection: View {
    @EnvironmentObject private var settings: SettingsModel
    @State private var editing: CharacterPoolTarget?

    private var isAutomatic: Bool { settings.settings.assignCharactersAutomatically }

    private var projectKeys: [String] {
        settings.settings.projectCharacterPools.keys.sorted {
            ProjectKey.displayName($0).localizedCaseInsensitiveCompare(ProjectKey.displayName($1)) == .orderedAscending
        }
    }

    var body: some View {
        Section {
            Toggle("Give sessions a character automatically", isOn: settings.binding(\.assignCharactersAutomatically))
            LabeledContent("Sessions show") {
                Text(isAutomatic
                    ? "A random character each, from \(CharacterCatalog.all.count) in \(CharacterWorld.allCases.count) worlds"
                    : "The Claude logo, unless you pick a character")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session characters")
        } footer: {
            Text(isAutomatic
                ? "Every session without a character gets a random one, different from the other open sessions where it can, and keeps it until it ends. Click a character in the notch to change it or to switch that session back to the Claude logo. Turning this off puts those sessions back on the Claude logo; characters you picked yourself stay."
                : "Every session shows the Claude logo. Click the logo on a session in the notch to give that one session a character; your pick stays whether this is on or off. Turn this on to have every session without a character get a random one by itself.")
        }

        Section {
            if projectKeys.isEmpty {
                Text("No project has its own collection. Automatic characters draw from all \(CharacterCatalog.all.count) for every project.")
                    .foregroundStyle(.secondary)
            }
            ForEach(projectKeys, id: \.self) { key in
                let pool = settings.characterPool(forProject: key)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ProjectKey.displayName(key))
                        Text(key)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    CharacterPoolStrip(characters: pool, limit: 5)
                    Button("Edit…") { editing = CharacterPoolTarget(key: key) }
                    Button("Remove") { settings.setCharacterPool([], forProject: key) }
                        .help("This project goes back to the whole collection")
                }
                .controlSize(.small)
            }
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
        } header: {
            Text("Project collections")
        } footer: {
            Text(isAutomatic
                ? "A project with its own collection gives new sessions a random character from that collection only. Changing a collection never changes a character a running session already wears."
                : "Collections are what automatic characters draw from once that is on. Until then they only narrow \"Surprise me\" in the notch; you can always pick any character for a session yourself.")
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
