import Foundation

// What's New: the visual release notes of one version.
//
// One JSON file per release lives in `ReleaseNotes/<version>.json`. At release
// time it is checked, written out in its published form and embedded in the
// signed update feed, in the same `<item>` as the download it describes. An
// installed copy therefore reads the notes of exactly the version it is being
// offered, authenticated by the same signature as the update itself.
//
// The published form is self-contained: an older app must be able to draw the
// notes of a newer release, so a visual carries its own data (a new
// character's pixels, say) instead of naming something only the new app has.

/// What kind of change a card describes.
public enum ReleaseCategory: String, CaseIterable, Sendable {
    case feature
    case improvement
    case fix
    /// A category from a newer format than this app knows. Shown as a plain
    /// "Update"; never published by this version's tools.
    case other

    public var displayName: String {
        switch self {
        case .feature: "New Feature"
        case .improvement: "Improvement"
        case .fix: "Bug Fix"
        case .other: "Update"
        }
    }

    /// "1 new feature", "3 bug fixes".
    public func counted(_ count: Int) -> String {
        let one = count == 1
        switch self {
        case .feature: return "\(count) new feature\(one ? "" : "s")"
        case .improvement: return "\(count) improvement\(one ? "" : "s")"
        case .fix: return "\(count) bug fix\(one ? "" : "es")"
        case .other: return "\(count) other update\(one ? "" : "s")"
        }
    }
}

extension ReleaseCategory: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReleaseCategory(rawValue: raw) ?? .other
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A pixel drawing carried inside the notes: 16 rows of 16 letters, one
/// letter per colour, "." for nothing. The same format the app's own
/// characters use, so a release can show a character the installed app has
/// never heard of.
public struct ReleaseSprite: Equatable, Sendable {
    public var name: String
    /// "LETTER:RRGGBB" pairs separated by commas.
    public var palette: String
    public var rows: [String]

    public init(name: String, palette: String, rows: [String]) {
        self.name = name
        self.palette = palette
        self.rows = rows
    }

    /// The sprite of one of this build's own characters.
    public init(character: SessionCharacter) {
        name = character.name
        palette = character.colors.keys.sorted().map { letter in
            "\(letter):" + String(format: "%06X", character.colors[letter] ?? 0)
        }.joined(separator: ",")
        rows = character.standing
    }

    /// The sprite as something the app's character views can draw.
    public var character: SessionCharacter {
        SessionCharacter(id: "release-notes.\(name)", name: name, world: .animals, palette: palette, standing: rows)
    }
}

extension ReleaseSprite: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, palette, rows, character
    }

    /// The source file may name one of the app's characters
    /// (`{"character": "animals.cat"}`); it is always written out in full.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .character) {
            guard let character = CharacterCatalog.character(id: id) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .character, in: container,
                    debugDescription: "There is no character called \(id)."
                )
            }
            self.init(character: character)
            return
        }
        self.init(
            name: try container.decode(String.self, forKey: .name),
            palette: try container.decode(String.self, forKey: .palette),
            rows: try container.decode([String].self, forKey: .rows)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(palette, forKey: .palette)
        try container.encode(rows, forKey: .rows)
    }
}

/// How a session row in a notch illustration reads.
public enum ReleaseRowStatus: String, Sendable {
    case working
    case needsYou
    case done
    case failed
    case idle
}

extension ReleaseRowStatus: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReleaseRowStatus(rawValue: raw) ?? .idle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A permission card under a session row in a notch illustration.
public struct ReleasePermissionCard: Codable, Equatable, Sendable {
    /// The tool, as the card names it ("Bash").
    public var tool: String
    /// What the tool is asked to do ("npm test").
    public var request: String
    public var buttons: [String]
    /// The line under the buttons, when the card has one.
    public var caption: String?

    public init(tool: String, request: String, buttons: [String], caption: String? = nil) {
        self.tool = tool
        self.request = request
        self.buttons = buttons
        self.caption = caption
    }
}

/// One session row in a notch illustration.
public struct ReleaseNotchRow: Codable, Equatable, Sendable {
    public var title: String
    public var status: ReleaseRowStatus
    public var detail: String?
    /// The row's mark; the Claude logo when nil.
    public var sprite: ReleaseSprite?
    public var permission: ReleasePermissionCard?

    public init(
        title: String,
        status: ReleaseRowStatus,
        detail: String? = nil,
        sprite: ReleaseSprite? = nil,
        permission: ReleasePermissionCard? = nil
    ) {
        self.title = title
        self.status = status
        self.detail = detail
        self.sprite = sprite
        self.permission = permission
    }
}

/// One side of a before-and-after illustration.
public struct ReleaseComparisonSide: Codable, Equatable, Sendable {
    public var label: String
    public var rows: [ReleaseNotchRow]

    public init(label: String, rows: [ReleaseNotchRow]) {
        self.label = label
        self.rows = rows
    }
}

/// A picture published beside the release's download. The notes pin its
/// SHA-256, so the app shows only the exact bytes the release was made with.
public struct ReleaseImage: Codable, Equatable, Sendable {
    /// A bare file name such as "picker.png": no folders, PNG only.
    public var file: String
    /// Lower-case hex. Filled in when the notes are published.
    public var sha256: String?
    /// The picture's size in pixels. Filled in when the notes are published.
    public var width: Int?
    public var height: Int?
    /// What the picture shows, for VoiceOver and for when it cannot load.
    public var alt: String

    public init(file: String, sha256: String? = nil, width: Int? = nil, height: Int? = nil, alt: String) {
        self.file = file
        self.sha256 = sha256
        self.width = width
        self.height = height
        self.alt = alt
    }
}

/// What a card shows above its text.
public enum ReleaseVisual: Equatable, Sendable {
    /// Pixel characters, side by side.
    case sprites([ReleaseSprite], caption: String?)
    /// The open notch with up to three session rows.
    case notch([ReleaseNotchRow], caption: String?)
    /// Two notch rows' worth of "before" and "now".
    case comparison(before: ReleaseComparisonSide, after: ReleaseComparisonSide)
    case image(ReleaseImage)
    /// A kind this app does not know, or one it could not read. The card is
    /// shown without a visual; nothing is put in its place.
    case unsupported(kind: String)

    public var kind: String {
        switch self {
        case .sprites: "sprites"
        case .notch: "notch"
        case .comparison: "comparison"
        case .image: "image"
        case let .unsupported(kind): kind
        }
    }

    public var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

extension ReleaseVisual: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, sprites, rows, caption, before, after, image
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        do {
            switch kind {
            case "sprites":
                self = .sprites(
                    try container.decode([ReleaseSprite].self, forKey: .sprites),
                    caption: try container.decodeIfPresent(String.self, forKey: .caption)
                )
            case "notch":
                self = .notch(
                    try container.decode([ReleaseNotchRow].self, forKey: .rows),
                    caption: try container.decodeIfPresent(String.self, forKey: .caption)
                )
            case "comparison":
                self = .comparison(
                    before: try container.decode(ReleaseComparisonSide.self, forKey: .before),
                    after: try container.decode(ReleaseComparisonSide.self, forKey: .after)
                )
            case "image":
                self = .image(try container.decode(ReleaseImage.self, forKey: .image))
            default:
                self = .unsupported(kind: kind)
            }
        } catch {
            // A visual this app cannot read costs the card its picture, not
            // the release its notes.
            self = .unsupported(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .sprites(sprites, caption):
            try container.encode(sprites, forKey: .sprites)
            try container.encodeIfPresent(caption, forKey: .caption)
        case let .notch(rows, caption):
            try container.encode(rows, forKey: .rows)
            try container.encodeIfPresent(caption, forKey: .caption)
        case let .comparison(before, after):
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        case let .image(image):
            try container.encode(image, forKey: .image)
        case .unsupported:
            break
        }
    }
}

/// One change, as one card of the walkthrough.
public struct ReleaseCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var category: ReleaseCategory
    public var title: String
    /// One or two sentences: what changed and why it matters.
    public var summary: String
    /// Optional further points, shown as a short list.
    public var details: [String]?
    public var visual: ReleaseVisual?

    public init(
        id: String,
        category: ReleaseCategory,
        title: String,
        summary: String,
        details: [String]? = nil,
        visual: ReleaseVisual? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.details = details
        self.visual = visual
    }
}

/// The release notes of one version.
public struct ReleaseNotes: Codable, Equatable, Sendable {
    /// The newest format this build reads and writes. Changes that an older
    /// app can ignore (a new visual kind, a new optional field) do not raise
    /// it; only a change an older app would misread does.
    public static let currentSchema = 1

    public var schema: Int
    public var version: String
    /// The release date, as "2026-11-24".
    public var date: String
    public var introduction: String
    public var cards: [ReleaseCard]

    public init(
        schema: Int = ReleaseNotes.currentSchema,
        version: String,
        date: String,
        introduction: String,
        cards: [ReleaseCard]
    ) {
        self.schema = schema
        self.version = version
        self.date = date
        self.introduction = introduction
        self.cards = cards
    }

    /// How many cards each category has, in the order the app lists them.
    public var categoryCounts: [(category: ReleaseCategory, count: Int)] {
        ReleaseCategory.allCases.compactMap { category in
            let count = cards.count { $0.category == category }
            return count > 0 ? (category, count) : nil
        }
    }

    /// "2 new features · 1 improvement · 3 bug fixes".
    public var summaryLine: String {
        categoryCounts.map { $0.category.counted($0.count) }.joined(separator: " · ")
    }

    /// The date as people read it ("24 November 2026"), or nil when the
    /// notes' date is not a real day.
    public var displayDate: String? {
        guard let day = ReleaseNotes.day(from: date) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: day)
    }

    static func day(from text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        // Calendar rolls 2026-02-31 over into March; a real day comes back as itself.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day ? date : nil
    }

    /// The published form: compact, with keys in a fixed order so the same
    /// notes always produce the same bytes.
    public func published() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
