import CryptoKit
import Foundation

// MARK: - Pictures

/// The rules for a picture a release publishes beside its download.
public enum ReleaseImageCheck {
    /// The most the app will download for one picture.
    public static let maximumBytes = 4 * 1_024 * 1_024
    static let maximumSide = 4_096
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A bare lower-case PNG name: no folders, nothing a URL could misread.
    public static func isSafeFileName(_ name: String) -> Bool {
        guard name.count <= 64, name.hasSuffix(".png"), let first = name.unicodeScalars.first,
              isLetterOrDigit(first) else { return false }
        return name.unicodeScalars.allSatisfy { isLetterOrDigit($0) || $0 == "." || $0 == "-" || $0 == "_" }
            && !name.contains("..")
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    /// The size a PNG declares in its header, in pixels.
    public static func pngSize(of data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == pngSignature,
              Array(bytes[12..<16]) == Array("IHDR".utf8) else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        guard (1...maximumSide).contains(width), (1...maximumSide).contains(height) else { return nil }
        return (width, height)
    }

    /// Whether these bytes are the picture the notes describe: a PNG of the
    /// stated size whose SHA-256 is the one the signed notes pin.
    public static func accepts(_ data: Data, for image: ReleaseImage) -> Bool {
        guard data.count <= maximumBytes, let expected = image.sha256, let size = pngSize(of: data),
              size.width == image.width, size.height == image.height else { return false }
        return sha256(of: data) == expected.lowercased()
    }

    /// Where the picture is served: next to the release's download. Only
    /// over https, or from this Mac for the local update test.
    public static func url(for image: ReleaseImage, base: URL) -> URL? {
        guard isSafeFileName(image.file), let scheme = base.scheme?.lowercased() else { return nil }
        let isLocalTest = scheme == "http" && (base.host == "localhost" || base.host == "127.0.0.1")
        guard scheme == "https" || isLocalTest else { return nil }
        return base.appendingPathComponent(image.file)
    }
}

// MARK: - Checking notes before they ship

/// The checks a release's notes must pass before they are published. The
/// app itself is more forgiving (see `ReleaseNotesReader`): what an old copy
/// cannot draw it leaves out. These rules are for the people writing notes.
public enum ReleaseNotesValidator {
    /// The appcast is fetched hourly by every installed copy; the notes
    /// travel inside it.
    public static let maximumPublishedBytes = 64 * 1_024
    static let cardCount = 1...12
    static let maximumTitle = 60
    static let maximumSummary = 240
    static let maximumIntroduction = 280
    static let maximumDetails = 5
    static let maximumDetail = 200
    static let maximumCaption = 90
    static let maximumSprites = 12
    static let maximumRows = 3
    static let maximumComparisonRows = 2

    /// Everything wrong with these notes; empty when they are fit to ship.
    /// `published` also requires what publishing fills in (picture hashes).
    public static func problems(in notes: ReleaseNotes, published: Bool = false) -> [String] {
        var problems: [String] = []
        if notes.schema != ReleaseNotes.currentSchema {
            problems.append("schema is \(notes.schema); this version writes \(ReleaseNotes.currentSchema).")
        }
        if AppVersion(notes.version) == nil || notes.version.split(separator: ".").count != 3 {
            problems.append("version \"\(notes.version)\" is not of the form 1.2.3.")
        }
        if ReleaseNotes.day(from: notes.date) == nil {
            problems.append("date \"\(notes.date)\" is not a real day written as 2026-11-24.")
        }
        check(notes.introduction, "introduction", atMost: maximumIntroduction, into: &problems)
        if !cardCount.contains(notes.cards.count) {
            problems.append("a release needs \(cardCount.lowerBound) to \(cardCount.upperBound) cards; this has \(notes.cards.count).")
        }
        var seen: Set<String> = []
        for card in notes.cards {
            let name = "card \"\(card.id)\""
            if card.id.isEmpty || !card.id.unicodeScalars.allSatisfy({
                ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
            }) {
                problems.append("\(name): the id may use lower-case letters, digits and hyphens only.")
            }
            if !seen.insert(card.id).inserted { problems.append("\(name): the id is used twice.") }
            if card.category == .other {
                problems.append("\(name): the category must be feature, improvement or fix.")
            }
            check(card.title, "\(name) title", atMost: maximumTitle, into: &problems)
            check(card.summary, "\(name) summary", atMost: maximumSummary, into: &problems)
            if let details = card.details {
                if details.isEmpty || details.count > maximumDetails {
                    problems.append("\(name): details, when given, hold 1 to \(maximumDetails) points.")
                }
                for detail in details { check(detail, "\(name) detail", atMost: maximumDetail, into: &problems) }
            }
            if let visual = card.visual {
                problems.append(contentsOf: Self.problems(in: visual, published: published).map { "\(name): \($0)" })
            }
        }
        if let data = try? notes.published() {
            if data.count > maximumPublishedBytes {
                problems.append("the published notes are \(data.count) bytes; the update feed carries at most \(maximumPublishedBytes).")
            }
            // The notes sit in a CDATA section of the feed.
            if String(decoding: data, as: UTF8.self).contains("]]>") {
                problems.append("the text \"]]>\" cannot appear anywhere in the notes.")
            }
        } else {
            problems.append("the notes cannot be written out as JSON.")
        }
        return problems
    }

    private static func problems(in visual: ReleaseVisual, published: Bool) -> [String] {
        var problems: [String] = []
        switch visual {
        case let .sprites(sprites, caption):
            if sprites.isEmpty || sprites.count > maximumSprites {
                problems.append("a sprites visual shows 1 to \(maximumSprites) characters.")
            }
            for sprite in sprites { problems.append(contentsOf: Self.problems(in: sprite)) }
            if let caption { check(caption, "caption", atMost: maximumCaption, into: &problems) }
        case let .notch(rows, caption):
            problems.append(contentsOf: Self.problems(in: rows, atMost: maximumRows))
            if let caption { check(caption, "caption", atMost: maximumCaption, into: &problems) }
        case let .comparison(before, after):
            for side in [before, after] {
                check(side.label, "comparison label", atMost: 16, into: &problems)
                problems.append(contentsOf: Self.problems(in: side.rows, atMost: maximumComparisonRows))
            }
        case let .image(image):
            if !ReleaseImageCheck.isSafeFileName(image.file) {
                problems.append("the picture \"\(image.file)\" must be a bare lower-case .png name.")
            }
            check(image.alt, "picture description", atMost: 160, into: &problems)
            if published {
                let hash = image.sha256 ?? ""
                if hash.count != 64 || !hash.unicodeScalars.allSatisfy({
                    ("0"..."9").contains($0) || ("a"..."f").contains($0)
                }) {
                    problems.append("the picture \"\(image.file)\" has no SHA-256.")
                }
                if image.width == nil || image.height == nil {
                    problems.append("the picture \"\(image.file)\" has no size.")
                }
            }
        case let .unsupported(kind):
            problems.append("the visual \"\(kind)\" is not one this version can draw, or it is malformed.")
        }
        return problems
    }

    private static func problems(in rows: [ReleaseNotchRow], atMost maximum: Int) -> [String] {
        var problems: [String] = []
        if rows.isEmpty || rows.count > maximum {
            problems.append("a notch illustration here shows 1 to \(maximum) session rows.")
        }
        for row in rows {
            check(row.title, "row title", atMost: 32, into: &problems)
            if let detail = row.detail { check(detail, "row detail", atMost: 56, into: &problems) }
            if let sprite = row.sprite { problems.append(contentsOf: Self.problems(in: sprite)) }
            if let card = row.permission {
                check(card.tool, "permission card tool", atMost: 24, into: &problems)
                check(card.request, "permission card request", atMost: 56, into: &problems)
                if card.buttons.isEmpty || card.buttons.count > 3 {
                    problems.append("a permission card has 1 to 3 buttons.")
                }
                for button in card.buttons { check(button, "permission card button", atMost: 14, into: &problems) }
                if let caption = card.caption { check(caption, "permission card caption", atMost: maximumCaption, into: &problems) }
            }
        }
        return problems
    }

    static func problems(in sprite: ReleaseSprite) -> [String] {
        let size = SessionCharacter.gridSize
        var problems: [String] = []
        check(sprite.name, "sprite name", atMost: 24, into: &problems)
        let colors = SessionCharacter.colors(from: sprite.palette)
        if colors.isEmpty || colors.count > 24 || colors.count != sprite.palette.split(separator: ",").count {
            problems.append("sprite \"\(sprite.name)\": the palette must be 1 to 24 well-formed LETTER:RRGGBB pairs.")
        }
        if sprite.rows.count != size || sprite.rows.contains(where: { $0.count != size }) {
            problems.append("sprite \"\(sprite.name)\": the drawing must be \(size) rows of \(size) letters.")
        } else if sprite.rows.joined().contains(where: { $0 != "." && colors[$0] == nil }) {
            problems.append("sprite \"\(sprite.name)\": a letter in the drawing has no colour in the palette.")
        } else if !sprite.rows.joined().contains(where: { $0 != "." }) {
            problems.append("sprite \"\(sprite.name)\": the drawing is empty.")
        }
        return problems
    }

    private static func check(_ text: String, _ what: String, atMost maximum: Int, into problems: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            problems.append("\(what) is empty.")
        } else if trimmed != text {
            problems.append("\(what) has space at its start or end.")
        } else if text.count > maximum {
            problems.append("\(what) is \(text.count) characters; the card fits \(maximum).")
        } else if text.contains("\n") {
            problems.append("\(what) must be one line.")
        }
    }
}

// MARK: - Publishing

public enum ReleaseNotesPublisher {
    /// The notes as they are published: every picture's SHA-256 and size
    /// filled in from the file itself, so they can never be mistyped.
    /// `asset` returns a picture's bytes, or nil when the file is missing.
    public static func publish(
        _ notes: ReleaseNotes,
        asset: (String) -> Data?
    ) -> (notes: ReleaseNotes, problems: [String]) {
        var result = notes
        var problems: [String] = []
        for index in result.cards.indices {
            guard case var .image(image) = result.cards[index].visual else { continue }
            guard ReleaseImageCheck.isSafeFileName(image.file), let data = asset(image.file) else {
                problems.append("card \"\(result.cards[index].id)\": the picture \"\(image.file)\" is not in the release's folder.")
                continue
            }
            guard data.count <= ReleaseImageCheck.maximumBytes, let size = ReleaseImageCheck.pngSize(of: data) else {
                problems.append("card \"\(result.cards[index].id)\": \"\(image.file)\" is not a PNG of at most \(ReleaseImageCheck.maximumBytes) bytes.")
                continue
            }
            image.sha256 = ReleaseImageCheck.sha256(of: data)
            image.width = size.width
            image.height = size.height
            result.cards[index].visual = .image(image)
        }
        problems.append(contentsOf: ReleaseNotesValidator.problems(in: result, published: true))
        return (result, problems)
    }

    /// The pictures these notes show, by file name.
    public static func imageFiles(in notes: ReleaseNotes) -> [String] {
        notes.cards.compactMap { card in
            if case let .image(image) = card.visual { return image.file }
            return nil
        }
    }
}

// MARK: - The release process

/// One released version, as CHANGELOG.md heads its section.
public struct ChangelogRelease: Equatable, Sendable {
    public let version: String
    public let date: String
}

/// The rule that makes What's New part of every release: from the first
/// version that had notes, no version ships without its own.
public enum ReleaseReadiness {
    /// The first release with What's New. Earlier ones have none.
    public static let firstVersionWithNotes = "1.1.0"

    /// The "## [1.2.3] - 2026-11-24" headings, newest first as written.
    public static func changelogReleases(in changelog: String) -> [ChangelogRelease] {
        changelog.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard line.hasPrefix("## ["), let close = line.firstIndex(of: "]") else { return nil }
            let version = String(line[line.index(line.startIndex, offsetBy: 4)..<close])
            guard AppVersion(version) != nil else { return nil }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("- ") else { return nil }
            return ChangelogRelease(version: version, date: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
    }

    public static func requiresNotes(_ version: String) -> Bool {
        guard let version = AppVersion(version), let first = AppVersion(firstVersionWithNotes) else { return false }
        return version >= first
    }

    /// What stands between the repository and a release. `notes` maps each
    /// file in `ReleaseNotes/` (by the version in its name) to what it
    /// holds. `releasing` is the version about to be published, when one is.
    public static func problems(
        changelog: String,
        appVersion: String,
        notes: [String: ReleaseNotes],
        releasing: String? = nil
    ) -> [String] {
        var problems: [String] = []
        for (fileVersion, release) in notes.sorted(by: { $0.key < $1.key }) {
            if release.version != fileVersion {
                problems.append("ReleaseNotes/\(fileVersion).json describes version \(release.version).")
            }
            problems.append(contentsOf: ReleaseNotesValidator.problems(in: release).map {
                "ReleaseNotes/\(fileVersion).json: \($0)"
            })
        }
        let released = changelogReleases(in: changelog)
        for release in released where requiresNotes(release.version) {
            guard let written = notes[release.version] else {
                problems.append("CHANGELOG.md lists \(release.version), but there is no ReleaseNotes/\(release.version).json.")
                continue
            }
            if written.date != release.date {
                problems.append("ReleaseNotes/\(release.version).json is dated \(written.date); CHANGELOG.md says \(release.date).")
            }
        }
        if requiresNotes(appVersion), notes[appVersion] == nil {
            problems.append("Packaging/Info.plist is at \(appVersion), but there is no ReleaseNotes/\(appVersion).json.")
        }
        if let releasing {
            if appVersion != releasing {
                problems.append("Packaging/Info.plist is at \(appVersion), not \(releasing).")
            }
            if !released.contains(where: { $0.version == releasing }) {
                problems.append("CHANGELOG.md has no dated section for \(releasing).")
            }
            if requiresNotes(releasing), notes[releasing] == nil {
                problems.append("There is no ReleaseNotes/\(releasing).json: every release ships its What's New.")
            }
        }
        return problems
    }
}

// MARK: - Reading notes in the app

/// Why an update's notes cannot be shown. The window says so plainly and
/// still offers the update; it never shows other notes in their place.
public enum ReleaseNotesProblem: Equatable, Sendable {
    /// The release was published without notes.
    case missing
    case unreadable
    /// Written in a format newer than this copy understands.
    case newerFormat
    /// The notes are for another version than the one on offer.
    case wrongVersion(found: String)
    case empty

    public var explanation: String {
        switch self {
        case .missing: "This release was published without visual release notes."
        case .unreadable: "The release notes for this version couldn't be read."
        case .newerFormat: "These release notes need a newer Claude Overhead to display."
        case .wrongVersion: "The release notes that came with this update are for another version, so they aren't shown."
        case .empty: "The release notes for this version are empty."
        }
    }
}

public enum ReleaseNotesContent: Equatable, Sendable {
    case notes(ReleaseNotes)
    case unavailable(ReleaseNotesProblem)

    public var notes: ReleaseNotes? {
        if case let .notes(notes) = self { return notes }
        return nil
    }
}

public enum ReleaseNotesReader {
    /// More than any real notes; bounds the work on a damaged feed.
    static let maximumBytes = 256 * 1_024
    static let maximumCards = 24

    /// The notes an update feed carries for the version it offers.
    public static func content(feedText: String?, expectedVersion: String) -> ReleaseNotesContent {
        guard let text = feedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .unavailable(.missing)
        }
        return content(data: Data(text.utf8), expectedVersion: expectedVersion)
    }

    /// Notes are shown only when they are for exactly `expectedVersion`.
    public static func content(data: Data, expectedVersion: String) -> ReleaseNotesContent {
        guard data.count <= maximumBytes else { return .unavailable(.unreadable) }
        struct Header: Decodable { let schema: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return .unavailable(.unreadable)
        }
        guard header.schema <= ReleaseNotes.currentSchema else { return .unavailable(.newerFormat) }
        guard header.schema >= 1, var notes = try? JSONDecoder().decode(ReleaseNotes.self, from: data) else {
            return .unavailable(.unreadable)
        }
        guard notes.version == expectedVersion else { return .unavailable(.wrongVersion(found: notes.version)) }
        notes.cards = notes.cards.prefix(maximumCards).compactMap(drawable)
        guard !notes.cards.isEmpty else { return .unavailable(.empty) }
        return .notes(notes)
    }

    /// A card as this copy can show it: one with no words is dropped, and a
    /// visual it cannot draw safely is left out.
    private static func drawable(_ card: ReleaseCard) -> ReleaseCard? {
        guard !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var card = card
        if let visual = card.visual, !isDrawable(visual) { card.visual = .unsupported(kind: visual.kind) }
        // More points than the card lays out: the first ones are shown.
        if let details = card.details, details.count > ReleaseNotesValidator.maximumDetails {
            card.details = Array(details.prefix(ReleaseNotesValidator.maximumDetails))
        }
        return card
    }

    /// Whether this window can lay the visual out: sound drawings, and no
    /// more of anything than the stage holds.
    private static func isDrawable(_ visual: ReleaseVisual) -> Bool {
        func sound(_ rows: [ReleaseNotchRow], atMost maximum: Int) -> Bool {
            (1...maximum).contains(rows.count) && rows.allSatisfy { row in
                (row.sprite.map { ReleaseNotesValidator.problems(in: $0).isEmpty } ?? true)
                    && (row.permission.map { (1...3).contains($0.buttons.count) } ?? true)
            }
        }
        switch visual {
        case let .sprites(sprites, _):
            return (1...ReleaseNotesValidator.maximumSprites).contains(sprites.count)
                && sprites.allSatisfy { ReleaseNotesValidator.problems(in: $0).isEmpty }
        case let .notch(rows, _):
            return sound(rows, atMost: ReleaseNotesValidator.maximumRows)
        case let .comparison(before, after):
            return sound(before.rows, atMost: ReleaseNotesValidator.maximumComparisonRows)
                && sound(after.rows, atMost: ReleaseNotesValidator.maximumComparisonRows)
        case let .image(image):
            return ReleaseImageCheck.isSafeFileName(image.file) && image.sha256 != nil
                && image.width != nil && image.height != nil
        case .unsupported:
            return false
        }
    }
}

// MARK: - An update on offer

/// An update the feed offers, with the notes that came with it. The notes
/// and the download are two parts of one signed feed entry, so what the
/// window describes is what "Update Now" installs.
public struct ReleaseOffer: Equatable, Sendable {
    public let version: String
    public let installedVersion: String
    public let content: ReleaseNotesContent
    /// The folder the release's download is served from; its pictures sit
    /// beside it.
    public let assetBase: URL?

    public init(version: String, installedVersion: String, content: ReleaseNotesContent, assetBase: URL?) {
        self.version = version
        self.installedVersion = installedVersion
        self.content = content
        self.assetBase = assetBase
    }

    /// The release's page on GitHub, for reading the notes there when they
    /// cannot be shown here.
    public var releasePage: URL? {
        guard AppVersion(version) != nil else { return nil }
        return URL(string: "https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v\(version)")
    }
}

/// Keeps "the notes shown" and "the version installed" the same thing.
public enum UpdateInstallGuard {
    /// Whether an update just found may be installed without being offered
    /// first. Only when it is the version the owner already chose, with
    /// "Update Now" under its notes. With no choice made, or a newer release
    /// that appeared in between, it is offered with its own notes.
    public static func installsWithoutOffering(found: String, chosen: String?) -> Bool {
        chosen == found
    }
}
