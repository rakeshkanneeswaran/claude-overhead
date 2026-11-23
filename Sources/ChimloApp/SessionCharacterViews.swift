import ChimloCore
import SwiftUI

/// What marks a session in the notch: the Claude logo, which is the default,
/// or the session's character once it has one.
struct SessionMark: View {
    let character: SessionCharacter?
    let mood: AvatarMood
    var size: CGFloat = 32
    var reduceMotion = false

    var body: some View {
        if let character {
            CharacterSprite(character: character, mood: mood, size: size, reduceMotion: reduceMotion)
        } else {
            ClaudeCodeMark(mood: mood, size: size, reduceMotion: reduceMotion)
        }
    }
}

/// One character, drawn as true pixel art: each sprite pixel is a whole
/// number of screen pixels, on a Retina display and on an ordinary one, so
/// it lands on the display's pixel grid. That matters more here than for the
/// one-colour Claude mark: between two colours, a pixel that straddles the
/// grid shows as a seam. The mood shows as motion: it bobs while Claude
/// works, and takes its raised pose while Claude waits on the owner (a
/// character with no raised pose hops instead). With Reduce Motion it stands
/// still.
struct CharacterSprite: View {
    let character: SessionCharacter
    var mood: AvatarMood = .idle
    var size: CGFloat = 32
    var reduceMotion = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if reduceMotion || !isAnimated {
                sprite(frame: 0)
            } else {
                TimelineView(.periodic(from: .now, by: interval)) { timeline in
                    sprite(frame: Int(timeline.date.timeIntervalSinceReferenceDate / interval) & 1)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(character.name), \(mood.accessibilityDescription)")
    }

    private var isWaiting: Bool { mood == .waiting || mood == .question }

    private var isAnimated: Bool { mood == .working || isWaiting }

    private var interval: TimeInterval { mood == .working ? 0.34 : 0.5 }

    private func sprite(frame: Int) -> some View {
        let rows = character.rows(raised: isWaiting && frame == 1)
        let lifts = frame == 1 && (mood == .working || (isWaiting && character.raised == nil))
        let opacity = mood == .idle ? 0.78 : 1
        let colors = character.colors
        let scale = max(1, displayScale)
        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvas in
            let geometry = CharacterSpriteGeometry(
                canvas: canvas,
                headroom: Self.headroom,
                displayScale: scale
            )
            let unit = geometry.unit
            let originX = geometry.origin.x
            let originY = lifts ? geometry.liftedY : geometry.origin.y
            var paths: [Character: Path] = [:]
            for (row, line) in rows.enumerated() {
                for (column, cell) in line.enumerated() where cell != "." {
                    paths[cell, default: Path()].addRect(CGRect(
                        x: originX + CGFloat(column) * unit,
                        y: originY + CGFloat(row) * unit,
                        width: unit,
                        height: unit
                    ))
                }
            }
            for (letter, path) in paths {
                guard let rgb = colors[letter] else { continue }
                context.fill(path, with: .color(Color(characterRGB: rgb).opacity(opacity)))
            }
        }
        // A character fills its square, so the canvas reaches a little past
        // the frame above and below: a lift then has room and loses no row.
        .frame(width: size, height: size + Self.headroom * 2)
    }

    private static let headroom: CGFloat = 2
}

extension Color {
    /// A colour from a character palette entry, 0xRRGGBB.
    init(characterRGB value: UInt32) {
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Where a session row's mark sits, so a button can be laid over exactly it
/// while the rest of the row stays one click target.
struct CharacterMarkAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The character picker inside the open notch: every character grouped by
/// world, for the one session whose mark (Claude logo or character) was
/// clicked. A click changes that session's character at once.
struct CharacterPickerView: View {
    let session: SessionDisplayModel
    /// What the session shows now; nil while it shows the Claude logo.
    let current: SessionCharacter?
    /// How many characters this session's project draws from, when it has
    /// its own collection.
    let projectPoolCount: Int?
    let reduceMotion: Bool
    let back: () -> Void
    let choose: (SessionCharacter) -> Void
    let useClaudeLogo: () -> Void
    let shuffle: () -> Void
    /// How many characters fit across the panel.
    var columnCount = 8

    private var currentID: String? { current?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    thisSession
                    ForEach(CharacterWorld.allCases, id: \.self) { world in
                        worldSection(world)
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 6)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Character for \(session.displayTitle)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Sessions")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(ChimloTheme.quietPaper)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(ChimloTheme.badgeInk)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to all sessions")
            .accessibilityLabel("Back to all sessions")

            SessionMark(character: current, mood: .idle, size: 26, reduceMotion: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChimloTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(statusLine)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ChimloTheme.mutedPaper)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var statusLine: String {
        let wearing = current.map { "Wearing \($0.name)" } ?? "Showing the Claude logo"
        guard let projectPoolCount else { return wearing }
        let noun = projectPoolCount == 1 ? "character" : "characters"
        return "\(wearing) · this project's collection has \(projectPoolCount) \(noun)"
    }

    /// The two choices that are not one particular character: back to the
    /// Claude logo, and a random character.
    private var thisSession: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("This session", count: nil)
            HStack(spacing: 6) {
                Button(action: useClaudeLogo) {
                    HStack(spacing: 7) {
                        ClaudeCodeMark(mood: .success, size: 26, reduceMotion: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Claude logo")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(ChimloTheme.paper)
                            Text("The default, no character")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(ChimloTheme.mutedPaper)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 40)
                    .background(ChimloTheme.raisedInk)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(selectionBorder(current == nil))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Switches this session back to the Claude logo")
                .accessibilityLabel("Claude logo for this session")
                .accessibilityAddTraits(current == nil ? .isSelected : [])

                Button(action: shuffle) {
                    HStack(spacing: 6) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ChimloTheme.providerOrange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Surprise me")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(ChimloTheme.paper)
                            Text("A random character")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(ChimloTheme.mutedPaper)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 40)
                    .background(ChimloTheme.raisedInk)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Draws another character for this session")
                .accessibilityLabel("Give this session another random character")
            }
        }
    }

    private func worldSection(_ world: CharacterWorld) -> some View {
        let characters = CharacterCatalog.characters(in: world)
        return VStack(alignment: .leading, spacing: 5) {
            sectionTitle(world.displayName, count: characters.count)
            // An eager grid, not a lazy one: lazy layouts inside this panel's
            // scroll view can spin SwiftUI's placement on macOS (see the
            // session list), and 46 small cells cost nothing to build.
            Grid(alignment: .topLeading, horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Self.rows(of: characters, columns: columnCount), id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { character in
                            CharacterPickerCell(
                                character: character,
                                isSelected: character.id == currentID,
                                action: { choose(character) }
                            )
                        }
                        // Pad a short last row so its cells keep the width
                        // of the rows above.
                        ForEach(row.count..<max(row.count, columnCount), id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes(.vertical)
                        }
                    }
                }
            }
        }
    }

    static func rows(of characters: [SessionCharacter], columns: Int) -> [[SessionCharacter]] {
        let width = max(1, columns)
        return stride(from: 0, to: characters.count, by: width).map {
            Array(characters[$0..<min($0 + width, characters.count)])
        }
    }

    /// As many 72-point columns as fit, never fewer than four.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(4, Int((width + 6) / 72))
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(ChimloTheme.quietPaper)
            if let count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ChimloTheme.mutedPaper)
            }
        }
    }

    private func selectionBorder(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(selected ? ChimloTheme.providerOrange : .clear, lineWidth: 1.5)
            .allowsHitTesting(false)
    }
}

private struct CharacterPickerCell: View {
    let character: SessionCharacter
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                CharacterSprite(character: character, mood: .success, size: 34, reduceMotion: true)
                Text(character.name)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(isSelected ? ChimloTheme.paper : ChimloTheme.quietPaper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 3)
            .background(isHovering ? ChimloTheme.badgeInk : ChimloTheme.raisedInk)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? ChimloTheme.providerOrange : isHovering ? ChimloTheme.rowHoverEdge : .clear,
                        lineWidth: 1.5
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(character.name)
        .accessibilityLabel(character.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
