import Foundation
import Testing
@testable import ChimloCore

@Suite("What's New: release notes")
struct ReleaseNotesTests {
    static let cat = ReleaseSprite(character: CharacterCatalog.character(id: "animals.cat")!)

    static func notes(
        version: String = "1.2.0",
        date: String = "2026-12-01",
        cards: [ReleaseCard]? = nil
    ) -> ReleaseNotes {
        ReleaseNotes(
            version: version,
            date: date,
            introduction: "A short introduction to the release.",
            cards: cards ?? [
                ReleaseCard(
                    id: "characters", category: .feature, title: "Characters",
                    summary: "Sessions can wear a character.",
                    details: ["One point.", "Another point."],
                    visual: .sprites([cat], caption: "One of them")
                ),
                ReleaseCard(id: "polish", category: .improvement, title: "Polish", summary: "Things are smoother."),
                ReleaseCard(id: "crash", category: .fix, title: "A crash", summary: "It no longer crashes."),
            ]
        )
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    /// The first 24 bytes of a PNG of this size, then whatever follows.
    static func png(width: Int, height: Int, tail: [UInt8] = [1, 2, 3]) -> Data {
        func big(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * (3 - $0))) & 0xFF) } }
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + big(13) + Array("IHDR".utf8) + big(width) + big(height) + tail)
    }

    // MARK: The format

    @Test("Notes written out and read back are the same notes, byte for byte the second time")
    func roundTrip() throws {
        let notes = Self.notes()
        let published = try notes.published()
        #expect(ReleaseNotesReader.content(data: published, expectedVersion: "1.2.0") == .notes(notes))
        #expect(try JSONDecoder().decode(ReleaseNotes.self, from: published).published() == published)
        #expect(notes.summaryLine == "1 new feature · 1 improvement · 1 bug fix")
        #expect(notes.displayDate == "1 December 2026")
    }

    @Test("A source file names a character; the published notes carry its pixels")
    func characterReferencesAreWrittenOut() throws {
        let source = Self.json("""
        {"schema":1,"version":"1.2.0","date":"2026-12-01","introduction":"Intro.","cards":[
          {"id":"c","category":"feature","title":"T","summary":"S",
           "visual":{"kind":"sprites","sprites":[{"character":"animals.cat"}]}}]}
        """)
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: source)
        #expect(notes.cards[0].visual == .sprites([Self.cat], caption: nil))
        let published = String(decoding: try notes.published(), as: UTF8.self)
        // An older app has no such character: it must be able to draw it anyway.
        #expect(!published.contains("\"character\""))
        #expect(published.contains("\"rows\":["))
        #expect(Self.cat.character.standing == CharacterCatalog.character(id: "animals.cat")?.standing)
        #expect(Self.cat.character.colors == CharacterCatalog.character(id: "animals.cat")?.colors)
    }

    @Test("A character that does not exist is not silently dropped from a source file")
    func unknownCharacterIsAProblem() throws {
        let source = Self.json("""
        {"schema":1,"version":"1.2.0","date":"2026-12-01","introduction":"Intro.","cards":[
          {"id":"c","category":"feature","title":"T","summary":"S",
           "visual":{"kind":"sprites","sprites":[{"character":"animals.unicorn-cat"}]}}]}
        """)
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: source)
        #expect(notes.cards[0].visual == .unsupported(kind: "sprites"))
        #expect(ReleaseNotesValidator.problems(in: notes).contains { $0.contains("not one this version can draw") })
    }

    @Test("A visual or category from a newer format costs a card its picture, never the notes")
    func newerPartsDegrade() throws {
        let data = Self.json("""
        {"schema":1,"version":"1.2.0","date":"2026-12-01","introduction":"Intro.","cards":[
          {"id":"a","category":"feature","title":"Hologram","summary":"S","visual":{"kind":"hologram","depth":3}},
          {"id":"b","category":"experiment","title":"Other","summary":"S"},
          {"id":"c","category":"fix","title":"Broken notch","summary":"S","visual":{"kind":"notch","rows":"not rows"}}]}
        """)
        guard case let .notes(notes) = ReleaseNotesReader.content(data: data, expectedVersion: "1.2.0") else {
            Issue.record("the notes should still be shown")
            return
        }
        #expect(notes.cards.count == 3)
        #expect(notes.cards[0].visual == .unsupported(kind: "hologram"))
        #expect(notes.cards[0].visual?.isSupported == false)
        #expect(notes.cards[1].category == .other)
        #expect(ReleaseCategory.other.displayName == "Update")
        #expect(notes.cards[2].visual == .unsupported(kind: "notch"))
        // None of that may be published by this version.
        let problems = ReleaseNotesValidator.problems(in: notes)
        #expect(problems.contains { $0.contains("\"hologram\"") })
        #expect(problems.contains { $0.contains("feature, improvement or fix") })
    }

    // MARK: What the app shows

    @Test("Notes are shown only for exactly the version on offer")
    func notesMustMatchTheVersion() throws {
        let published = try Self.notes(version: "1.0.9").published()
        #expect(ReleaseNotesReader.content(data: published, expectedVersion: "1.1.0") == .unavailable(.wrongVersion(found: "1.0.9")))
        #expect(ReleaseNotesReader.content(data: published, expectedVersion: "1.0.9").notes?.version == "1.0.9")
        // Not even a version that compares equal as a number.
        #expect(ReleaseNotesReader.content(data: try Self.notes(version: "1.1").published(), expectedVersion: "1.1.0")
            == .unavailable(.wrongVersion(found: "1.1")))
    }

    @Test("Missing, unreadable, newer and empty notes each say so, and nothing is shown in their place")
    func honestFallbacks() throws {
        #expect(ReleaseNotesReader.content(feedText: nil, expectedVersion: "1.2.0") == .unavailable(.missing))
        #expect(ReleaseNotesReader.content(feedText: "  \n ", expectedVersion: "1.2.0") == .unavailable(.missing))
        #expect(ReleaseNotesReader.content(feedText: "<p>Bug fixes</p>", expectedVersion: "1.2.0") == .unavailable(.unreadable))
        #expect(ReleaseNotesReader.content(feedText: "{\"schema\":1}", expectedVersion: "1.2.0") == .unavailable(.unreadable))
        #expect(ReleaseNotesReader.content(feedText: "{\"schema\":0,\"version\":\"1.2.0\"}", expectedVersion: "1.2.0") == .unavailable(.unreadable))

        var newer = Self.notes()
        newer.schema = ReleaseNotes.currentSchema + 1
        #expect(ReleaseNotesReader.content(data: try newer.published(), expectedVersion: "1.2.0") == .unavailable(.newerFormat))

        #expect(ReleaseNotesReader.content(data: try Self.notes(cards: []).published(), expectedVersion: "1.2.0") == .unavailable(.empty))
        let blank = ReleaseCard(id: "x", category: .fix, title: "  ", summary: "S")
        #expect(ReleaseNotesReader.content(data: try Self.notes(cards: [blank]).published(), expectedVersion: "1.2.0") == .unavailable(.empty))

        let huge = Data(repeating: 0x20, count: ReleaseNotesReader.maximumBytes + 1)
        #expect(ReleaseNotesReader.content(data: huge, expectedVersion: "1.2.0") == .unavailable(.unreadable))
        for problem: ReleaseNotesProblem in [.missing, .unreadable, .newerFormat, .wrongVersion(found: "9"), .empty] {
            #expect(!problem.explanation.isEmpty)
        }
    }

    @Test("A drawing the app could not draw safely is left out, with its card kept")
    func malformedDrawingsAreLeftOut() throws {
        var short = Self.cat
        short.rows.removeLast()
        var stray = Self.cat
        stray.rows[0] = String(repeating: "~", count: 16)
        let unpinned = ReleaseImage(file: "a.png", alt: "A")
        let cards = [
            ReleaseCard(id: "a", category: .feature, title: "A", summary: "S", visual: .sprites([short], caption: nil)),
            ReleaseCard(id: "b", category: .feature, title: "B", summary: "S",
                        visual: .notch([ReleaseNotchRow(title: "r", status: .working, sprite: stray)], caption: nil)),
            ReleaseCard(id: "c", category: .feature, title: "C", summary: "S", visual: .image(unpinned)),
            ReleaseCard(id: "d", category: .feature, title: "D", summary: "S", visual: .sprites([Self.cat], caption: nil)),
        ]
        let read = ReleaseNotesReader.content(data: try Self.notes(cards: cards).published(), expectedVersion: "1.2.0").notes
        #expect(read?.cards.map(\.visual?.isSupported) == [false, false, false, true])
    }

    @Test("An offer links to its own release page, and only for a well-formed version")
    func offer() {
        let offer = ReleaseOffer(version: "1.2.0", installedVersion: "1.1.0", content: .unavailable(.missing), assetBase: nil)
        #expect(offer.releasePage?.absoluteString == "https://github.com/rakeshkanneeswaran/claude-overhead/releases/tag/v1.2.0")
        #expect(ReleaseOffer(version: "1.2.0/../x", installedVersion: "", content: .unavailable(.missing), assetBase: nil).releasePage == nil)
    }

    @Test("Only the version the owner chose is installed without being offered first")
    func installGuard() {
        #expect(UpdateInstallGuard.installsWithoutOffering(found: "1.2.0", chosen: "1.2.0"))
        #expect(!UpdateInstallGuard.installsWithoutOffering(found: "1.3.0", chosen: "1.2.0"))
        // No choice was made (a check that failed and was tried again): what
        // is found is offered, never installed.
        #expect(!UpdateInstallGuard.installsWithoutOffering(found: "1.2.0", chosen: nil))
    }

    @Test("A card holding more than the window lays out loses its visual or its extra points, not its place")
    func oversizedCards() throws {
        let row = ReleaseNotchRow(title: "api", status: .working)
        let fourButtons = ReleasePermissionCard(tool: "Bash", request: "x", buttons: ["a", "b", "c", "d"])
        let cards = [
            ReleaseCard(id: "a", category: .feature, title: "A", summary: "S",
                        visual: .sprites(Array(repeating: Self.cat, count: 13), caption: nil)),
            ReleaseCard(id: "b", category: .feature, title: "B", summary: "S", visual: .notch([row, row, row, row], caption: nil)),
            ReleaseCard(id: "c", category: .feature, title: "C", summary: "S", visual: .comparison(
                before: ReleaseComparisonSide(label: "Before", rows: [row, row, row]),
                after: ReleaseComparisonSide(label: "Now", rows: [row])
            )),
            ReleaseCard(id: "d", category: .feature, title: "D", summary: "S",
                        visual: .notch([ReleaseNotchRow(title: "api", status: .needsYou, permission: fourButtons)], caption: nil)),
            ReleaseCard(id: "e", category: .fix, title: "E", summary: "S", details: (1...9).map { "Point \($0)" }),
            ReleaseCard(id: "f", category: .feature, title: "F", summary: "S", visual: .notch([row, row, row], caption: nil)),
        ]
        let read = try #require(
            ReleaseNotesReader.content(data: try Self.notes(cards: cards).published(), expectedVersion: "1.2.0").notes
        )
        #expect(read.cards.map(\.visual?.isSupported) == [false, false, false, false, nil, true])
        #expect(read.cards[4].details == (1...5).map { "Point \($0)" })
    }

    // MARK: Pictures

    @Test("A picture is shown only when its bytes are the ones the notes pin")
    func picturesArePinned() {
        let data = Self.png(width: 320, height: 160)
        let image = ReleaseImage(file: "picker.png", sha256: ReleaseImageCheck.sha256(of: data), width: 320, height: 160, alt: "The picker")
        #expect(ReleaseImageCheck.accepts(data, for: image))
        #expect(!ReleaseImageCheck.accepts(Self.png(width: 320, height: 160, tail: [9]), for: image))
        var wrongSize = image
        wrongSize.width = 321
        #expect(!ReleaseImageCheck.accepts(data, for: wrongSize))
        var unpinned = image
        unpinned.sha256 = nil
        #expect(!ReleaseImageCheck.accepts(data, for: unpinned))
        #expect(!ReleaseImageCheck.accepts(Data("not a png".utf8), for: image))
        #expect(ReleaseImageCheck.pngSize(of: data)?.width == 320)
        #expect(ReleaseImageCheck.pngSize(of: Self.png(width: 0, height: 10)) == nil)
        #expect(ReleaseImageCheck.pngSize(of: Self.png(width: 99_999, height: 10)) == nil)
    }

    @Test("A picture is fetched only from beside the download, over https, by a plain name")
    func pictureAddresses() throws {
        let image = ReleaseImage(file: "picker.png", alt: "The picker")
        let release = try #require(URL(string: "https://github.com/rakeshkanneeswaran/claude-overhead/releases/download/v1.2.0/"))
        #expect(ReleaseImageCheck.url(for: image, base: release)?.absoluteString
            == "https://github.com/rakeshkanneeswaran/claude-overhead/releases/download/v1.2.0/picker.png")
        #expect(ReleaseImageCheck.url(for: image, base: try #require(URL(string: "http://localhost:55116/"))) != nil)
        #expect(ReleaseImageCheck.url(for: image, base: try #require(URL(string: "http://example.com/"))) == nil)
        #expect(ReleaseImageCheck.url(for: image, base: URL(fileURLWithPath: "/tmp/")) == nil)
        for bad in ["../secret.png", "a/b.png", "Picker.png", "picker.jpg", ".hidden.png", "a b.png", "a..png", ""] {
            #expect(!ReleaseImageCheck.isSafeFileName(bad), "\(bad)")
            #expect(ReleaseImageCheck.url(for: ReleaseImage(file: bad, alt: "x"), base: release) == nil, "\(bad)")
        }
        #expect(ReleaseImageCheck.isSafeFileName("whats-new_picker.2.png"))
    }

    @Test("Publishing fills in a picture's hash and size from the file itself")
    func publishing() {
        let data = Self.png(width: 640, height: 400)
        let card = ReleaseCard(id: "picker", category: .feature, title: "Picker", summary: "S",
                               visual: .image(ReleaseImage(file: "picker.png", alt: "The picker")))
        let notes = Self.notes(cards: [card])
        let published = ReleaseNotesPublisher.publish(notes) { $0 == "picker.png" ? data : nil }
        #expect(published.problems.isEmpty)
        #expect(published.notes.cards[0].visual == .image(ReleaseImage(
            file: "picker.png", sha256: ReleaseImageCheck.sha256(of: data), width: 640, height: 400, alt: "The picker"
        )))
        #expect(ReleaseNotesPublisher.imageFiles(in: published.notes) == ["picker.png"])

        let missing = ReleaseNotesPublisher.publish(notes) { _ in nil }
        #expect(missing.problems.contains { $0.contains("is not in the release's folder") })
        let notAPicture = ReleaseNotesPublisher.publish(notes) { _ in Data("hello".utf8) }
        #expect(notAPicture.problems.contains { $0.contains("is not a PNG") })
        // Written by hand, a hash is never trusted as published.
        #expect(ReleaseNotesValidator.problems(in: notes, published: true).contains { $0.contains("has no SHA-256") })
        #expect(ReleaseNotesValidator.problems(in: notes).isEmpty)
    }

    // MARK: The rules for writing notes

    @Test("Sound notes pass; each rule that is broken is named")
    func validation() {
        #expect(ReleaseNotesValidator.problems(in: Self.notes()).isEmpty)

        func problems(_ change: (inout ReleaseNotes) -> Void) -> [String] {
            var notes = Self.notes()
            change(&notes)
            return ReleaseNotesValidator.problems(in: notes)
        }
        #expect(problems { $0.version = "1.2" }.contains { $0.contains("not of the form 1.2.3") })
        #expect(problems { $0.version = "v1.2.0" }.contains { $0.contains("not of the form 1.2.3") })
        #expect(problems { $0.date = "2026-02-31" }.contains { $0.contains("not a real day") })
        #expect(problems { $0.date = "1 Dec 2026" }.contains { $0.contains("not a real day") })
        #expect(problems { $0.schema = 2 }.contains { $0.contains("schema is 2") })
        #expect(problems { $0.introduction = "" }.contains { $0.contains("introduction is empty") })
        #expect(problems { $0.cards = [] }.contains { $0.contains("needs 1 to 12 cards") })
        #expect(problems { $0.cards = Array(repeating: $0.cards[1], count: 13) }.contains { $0.contains("needs 1 to 12 cards") })
        #expect(problems { $0.cards[1].id = "characters" }.contains { $0.contains("used twice") })
        #expect(problems { $0.cards[1].id = "Polish It" }.contains { $0.contains("lower-case letters, digits and hyphens") })
        #expect(problems { $0.cards[1].title = String(repeating: "t", count: 61) }.contains { $0.contains("the card fits 60") })
        #expect(problems { $0.cards[1].summary = " padded " }.contains { $0.contains("space at its start or end") })
        #expect(problems { $0.cards[1].summary = "two\nlines" }.contains { $0.contains("must be one line") })
        #expect(problems { $0.cards[1].details = [] }.contains { $0.contains("details, when given") })
        #expect(problems { $0.cards[1].details = Array(repeating: "d", count: 6) }.contains { $0.contains("details, when given") })
        #expect(problems { $0.cards[1].summary = "breaks ]]> the feed" }.contains { $0.contains("]]>") })
        #expect(problems { $0.cards[1].category = .other }.contains { $0.contains("feature, improvement or fix") })
    }

    @Test("A visual is checked down to the last pixel and button")
    func visualValidation() {
        func problems(_ visual: ReleaseVisual) -> [String] {
            ReleaseNotesValidator.problems(in: Self.notes(cards: [
                ReleaseCard(id: "v", category: .feature, title: "V", summary: "S", visual: visual),
            ]))
        }
        #expect(problems(.sprites([], caption: nil)).contains { $0.contains("1 to 12 characters") })
        var ragged = Self.cat
        ragged.rows[3] = "short"
        #expect(problems(.sprites([ragged], caption: nil)).contains { $0.contains("16 rows of 16 letters") })
        var uncoloured = Self.cat
        uncoloured.palette = "A:FFFFFF"
        #expect(problems(.sprites([uncoloured], caption: nil)).contains { $0.contains("no colour in the palette") })
        var badPalette = Self.cat
        badPalette.palette = "A:FFFFFF,B:nope"
        #expect(problems(.sprites([badPalette], caption: nil)).contains { $0.contains("well-formed LETTER:RRGGBB") })
        var blank = Self.cat
        blank.rows = Array(repeating: String(repeating: ".", count: 16), count: 16)
        #expect(problems(.sprites([blank], caption: nil)).contains { $0.contains("is empty") })

        let row = ReleaseNotchRow(title: "api", status: .working)
        #expect(problems(.notch([], caption: nil)).contains { $0.contains("1 to 3 session rows") })
        #expect(problems(.notch([row, row, row, row], caption: nil)).contains { $0.contains("1 to 3 session rows") })
        #expect(problems(.notch([row], caption: String(repeating: "c", count: 91))).contains { $0.contains("caption") })
        let card = ReleasePermissionCard(tool: "Bash", request: "npm test", buttons: [])
        #expect(problems(.notch([ReleaseNotchRow(title: "api", status: .needsYou, permission: card)], caption: nil))
            .contains { $0.contains("1 to 3 buttons") })
        let side = ReleaseComparisonSide(label: "Before", rows: [row, row, row])
        #expect(problems(.comparison(before: side, after: ReleaseComparisonSide(label: "Now", rows: [row])))
            .contains { $0.contains("1 to 2 session rows") })
        #expect(problems(.image(ReleaseImage(file: "../x.png", alt: "x"))).contains { $0.contains("bare lower-case .png name") })
        #expect(problems(.unsupported(kind: "hologram")).contains { $0.contains("\"hologram\"") })
        #expect(problems(.notch([row], caption: "Fine")).isEmpty)
    }

    @Test("Notes too large for the update feed are refused")
    func sizeLimit() {
        let sprites = Array(repeating: Self.cat, count: 12)
        let cards = (0..<12).map { index in
            ReleaseCard(id: "c\(index)", category: .feature, title: "T", summary: "S",
                        details: Array(repeating: String(repeating: "d", count: 200), count: 5),
                        visual: .sprites(sprites, caption: nil))
        }
        let problems = ReleaseNotesValidator.problems(in: Self.notes(cards: cards))
        #expect(problems.contains { $0.contains("the update feed carries at most") })
    }
}

@Suite("What's New: part of every release")
struct ReleaseReadinessTests {
    static let changelog = """
    # Changelog

    ## [Unreleased]

    - Something new.

    ## [1.2.0] - 2026-12-01

    - A feature.

    ## [1.1.0] - 2026-11-24

    - Characters.

    ## [1.0.8] - 2026-11-23

    - Before What's New existed.

    [1.2.0]: https://example.com
    """

    static func notes(_ version: String, _ date: String) -> ReleaseNotes {
        ReleaseNotesTests.notes(version: version, date: date)
    }

    @Test("The changelog's dated sections are the released versions")
    func changelogReleases() {
        #expect(ReleaseReadiness.changelogReleases(in: Self.changelog) == [
            ChangelogRelease(version: "1.2.0", date: "2026-12-01"),
            ChangelogRelease(version: "1.1.0", date: "2026-11-24"),
            ChangelogRelease(version: "1.0.8", date: "2026-11-23"),
        ])
        #expect(ReleaseReadiness.requiresNotes("1.1.0"))
        #expect(ReleaseReadiness.requiresNotes("2.0.0"))
        #expect(!ReleaseReadiness.requiresNotes("1.0.8"))
    }

    @Test("From 1.1.0 on, a released version without its own notes is a problem")
    func everyReleaseNeedsNotes() {
        let complete = ["1.1.0": Self.notes("1.1.0", "2026-11-24"), "1.2.0": Self.notes("1.2.0", "2026-12-01")]
        #expect(ReleaseReadiness.problems(changelog: Self.changelog, appVersion: "1.2.0", notes: complete).isEmpty)
        #expect(ReleaseReadiness.problems(changelog: Self.changelog, appVersion: "1.2.0", notes: complete, releasing: "1.2.0").isEmpty)

        let missing = ReleaseReadiness.problems(
            changelog: Self.changelog, appVersion: "1.2.0", notes: ["1.1.0": Self.notes("1.1.0", "2026-11-24")]
        )
        #expect(missing.contains("CHANGELOG.md lists 1.2.0, but there is no ReleaseNotes/1.2.0.json."))
        #expect(missing.contains("Packaging/Info.plist is at 1.2.0, but there is no ReleaseNotes/1.2.0.json."))
        // 1.0.8 predates What's New and needs none.
        #expect(!missing.contains { $0.contains("1.0.8") })
    }

    @Test("Notes must be for their own file's version and carry the changelog's date")
    func notesAgreeWithTheRest() {
        let problems = ReleaseReadiness.problems(
            changelog: Self.changelog,
            appVersion: "1.2.0",
            notes: ["1.1.0": Self.notes("1.1.0", "2026-11-25"), "1.2.0": Self.notes("1.3.0", "2026-12-01")]
        )
        #expect(problems.contains("ReleaseNotes/1.1.0.json is dated 2026-11-25; CHANGELOG.md says 2026-11-24."))
        #expect(problems.contains("ReleaseNotes/1.2.0.json describes version 1.3.0."))
    }

    @Test("A version cannot be released until the app, the changelog and the notes all say it")
    func releasing() {
        let drafted = ["1.1.0": Self.notes("1.1.0", "2026-11-24"), "1.2.0": Self.notes("1.2.0", "2026-12-01"),
                       "1.3.0": Self.notes("1.3.0", "2026-12-20")]
        // The next release's notes may be written before it is released.
        #expect(ReleaseReadiness.problems(changelog: Self.changelog, appVersion: "1.2.0", notes: drafted).isEmpty)
        let early = ReleaseReadiness.problems(changelog: Self.changelog, appVersion: "1.2.0", notes: drafted, releasing: "1.3.0")
        #expect(early.contains("Packaging/Info.plist is at 1.2.0, not 1.3.0."))
        #expect(early.contains("CHANGELOG.md has no dated section for 1.3.0."))
        let without = ReleaseReadiness.problems(changelog: Self.changelog, appVersion: "1.4.0", notes: drafted, releasing: "1.4.0")
        #expect(without.contains("There is no ReleaseNotes/1.4.0.json: every release ships its What's New."))
        // Rebuilding a release from before What's New asks for no notes.
        #expect(ReleaseReadiness.problems(changelog: Self.changelog, appVersion: "1.0.8", notes: [:], releasing: "1.0.8")
            == ["CHANGELOG.md lists 1.2.0, but there is no ReleaseNotes/1.2.0.json.",
                "CHANGELOG.md lists 1.1.0, but there is no ReleaseNotes/1.1.0.json."])
    }

    @Test("A notes file with a broken rule fails the whole check, naming the file")
    func brokenNotesFail() {
        var broken = Self.notes("1.1.0", "2026-11-24")
        broken.cards[0].title = ""
        let problems = ReleaseReadiness.problems(changelog: Self.changelog, appVersion: "1.1.0", notes: ["1.1.0": broken])
        #expect(problems.contains { $0.hasPrefix("ReleaseNotes/1.1.0.json: ") && $0.contains("title is empty") })
    }

    // MARK: This repository

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func repositoryNotes() throws -> [String: ReleaseNotes] {
        let folder = root.appendingPathComponent("ReleaseNotes")
        var notes: [String: ReleaseNotes] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".json") {
            notes[String(file.dropLast(5))] = try JSONDecoder().decode(
                ReleaseNotes.self, from: Data(contentsOf: folder.appendingPathComponent(file))
            )
        }
        return notes
    }

    @Test("This repository's own notes, changelog and version agree")
    func repositoryIsInOrder() throws {
        let notes = try Self.repositoryNotes()
        #expect(!notes.isEmpty)
        let changelog = try String(contentsOf: Self.root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.root.appendingPathComponent("Packaging/Info.plist")), format: nil
        ) as? [String: Any]
        let appVersion = try #require(plist?["CFBundleShortVersionString"] as? String)
        let problems = ReleaseReadiness.problems(changelog: changelog, appVersion: appVersion, notes: notes)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("Every notes file in this repository publishes, and the app reads back exactly what was written")
    func repositoryNotesPublish() throws {
        for (version, release) in try Self.repositoryNotes() {
            let folder = Self.root.appendingPathComponent("ReleaseNotes/\(version)")
            let published = ReleaseNotesPublisher.publish(release) { try? Data(contentsOf: folder.appendingPathComponent($0)) }
            #expect(published.problems.isEmpty, "\(version): \(published.problems.joined(separator: "\n"))")
            let data = try published.notes.published()
            #expect(data.count <= ReleaseNotesValidator.maximumPublishedBytes)
            #expect(ReleaseNotesReader.content(data: data, expectedVersion: version) == .notes(published.notes))
            // Every visual is one this version's window draws.
            #expect(published.notes.cards.allSatisfy { $0.visual?.isSupported ?? true })
        }
    }
}

@Suite("What's New: the walkthrough")
struct WhatsNewWalkthroughTests {
    @Test("An overview, then one page per card, with no way off either end")
    func navigation() {
        var walkthrough = WhatsNewWalkthrough(cardCount: 3)
        #expect(walkthrough.pageCount == 4)
        #expect(walkthrough.page == .overview)
        #expect(walkthrough.progressLabel == "Overview")
        #expect(!walkthrough.canGoBack && walkthrough.canGoForward)
        walkthrough.previous()
        #expect(walkthrough.page == .overview)

        walkthrough.next()
        #expect(walkthrough.page == .card(0))
        #expect(walkthrough.progressLabel == "1 of 3")
        #expect(walkthrough.accessibilityProgress == "Change 1 of 3")
        walkthrough.next()
        walkthrough.next()
        #expect(walkthrough.page == .card(2))
        #expect(walkthrough.progressLabel == "3 of 3")
        #expect(walkthrough.isLastPage && !walkthrough.canGoForward)
        walkthrough.next()
        #expect(walkthrough.page == .card(2))

        walkthrough.open(card: 1)
        #expect(walkthrough.page == .card(1))
        walkthrough.go(to: 99)
        walkthrough.go(to: -1)
        walkthrough.open(card: 7)
        #expect(walkthrough.page == .card(1))
        walkthrough.previous()
        walkthrough.previous()
        #expect(walkthrough.page == .overview)
    }

    @Test("Notes that cannot be shown are a single page")
    func noCards() {
        var walkthrough = WhatsNewWalkthrough(cardCount: 0)
        #expect(walkthrough.pageCount == 1)
        walkthrough.next()
        #expect(walkthrough.page == .overview && walkthrough.isLastPage)
        #expect(WhatsNewWalkthrough(cardCount: -4).cardCount == 0)
        #expect(WhatsNewWalkthrough(cardCount: 1).accessibilityProgress == "Overview, 1 change follow")
    }

    @Test("The bottom of the window follows the update: offer, progress, failure")
    func updateStage() {
        #expect(WhatsNewUpdateStage(phase: nil) == .ready)
        #expect(WhatsNewUpdateStage(phase: .available(version: "1.2.0")) == .ready)
        #expect(WhatsNewUpdateStage(phase: .checking) == .working(label: "Checking for updates…", progress: nil))
        #expect(WhatsNewUpdateStage(phase: .downloading(progress: 0.42)) == .working(label: "Downloading update 42%", progress: 0.42))
        #expect(WhatsNewUpdateStage(phase: .downloading(progress: 7)) == .working(label: "Downloading update 100%", progress: 1))
        #expect(WhatsNewUpdateStage(phase: .preparing) == .working(label: "Verifying update…", progress: nil))
        #expect(WhatsNewUpdateStage(phase: .installing).isWorking)
        #expect(WhatsNewUpdateStage(phase: .restarting).isWorking)
        #expect(WhatsNewUpdateStage(phase: .upToDate) == .upToDate)
        #expect(WhatsNewUpdateStage(phase: .failed(.signatureMismatch)) == .failed(
            summary: "The update isn't signed by Claude Overhead",
            recovery: "It was refused, and nothing was installed.",
            canRetry: true,
            showsInstallCommand: false
        ))
        #expect(WhatsNewUpdateStage(phase: .failed(.notConfigured)) == .failed(
            summary: "This copy can't update itself",
            recovery: "Update once from Terminal with the install command; later versions update themselves.",
            canRetry: false,
            showsInstallCommand: true
        ))
    }

    @Test("Settings says where updates stand in a title and one line")
    func settingsSummary() {
        let idle = UpdateStatusSummary(phase: nil, installedVersion: "1.1.0")
        #expect(idle.tone == .neutral && idle.title == "Claude Overhead 1.1.0")
        let upToDate = UpdateStatusSummary(phase: .upToDate, installedVersion: "1.1.0")
        #expect(upToDate.tone == .good)
        #expect(upToDate.title == "You're up to date")
        #expect(upToDate.detail == "Claude Overhead 1.1.0 is the latest version.")
        let offer = UpdateStatusSummary(phase: .available(version: "1.2.0"), installedVersion: "1.1.0")
        #expect(offer.tone == .offer)
        #expect(offer.title == "Version 1.2.0 is available")
        #expect(offer.detail == "You have 1.1.0. See what's new, then update when you're ready.")
        #expect(UpdateStatusSummary(phase: .checking, installedVersion: "1.1.0").tone == .busy)
        #expect(UpdateStatusSummary(phase: .downloading(progress: 0.5), installedVersion: nil).tone == .busy)
        let failed = UpdateStatusSummary(phase: .failed(.offline), installedVersion: "1.1.0")
        #expect(failed.tone == .problem)
        #expect(failed.title == "Update failed: Can't reach GitHub")
        #expect(failed.detail == "Check your internet connection, then try again.")
        #expect(UpdateStatusSummary(phase: .upToDate, installedVersion: nil).detail == "This development build is the latest version.")
        // An offer's button opens What's New; it never names an install.
        #expect(AppUpdatePresentation(phase: .available(version: "1.2.0")).actionTitle == "See What's New")
    }
}
