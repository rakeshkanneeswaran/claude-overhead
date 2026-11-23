import Foundation
import Testing
@testable import ChimloCore

/// The characters are data: 46 grids typed by hand. A grid one pixel short or
/// a letter missing from its palette would draw a broken character, so every
/// one is checked.
@Suite("Character catalogue")
struct CharacterCatalogTests {
    @Test("Every world has characters and the ids are unique and stable in form")
    func idsAndWorlds() {
        let all = CharacterCatalog.all
        #expect(all.count == 46)
        #expect(Set(all.map(\.id)).count == all.count)
        for world in CharacterWorld.allCases {
            let inWorld = CharacterCatalog.characters(in: world)
            #expect(!inWorld.isEmpty, "\(world)")
            #expect(Set(inWorld.map(\.name)).count == inWorld.count, "names repeat in \(world)")
            #expect(!world.displayName.isEmpty)
        }
        for character in all {
            #expect(character.id.hasPrefix(character.world.rawValue + "."), "\(character.id)")
            #expect(character.id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "-" }, "\(character.id)")
            #expect(!character.name.isEmpty)
            #expect(CharacterCatalog.character(id: character.id) == character)
        }
        #expect(CharacterCatalog.character(id: "fantasy.nobody") == nil)
    }

    @Test("Every grid is 16 by 16 and uses only colours its palette names", arguments: CharacterCatalog.all)
    func grids(character: SessionCharacter) {
        let size = SessionCharacter.gridSize
        #expect(!character.colors.isEmpty)
        for (pose, grid) in [("standing", character.standing), ("raised", character.raised ?? character.standing)] {
            #expect(grid.count == size, "\(character.id) \(pose) has \(grid.count) rows")
            var filled = 0
            for (index, row) in grid.enumerated() {
                #expect(row.count == size, "\(character.id) \(pose) row \(index) is \(row.count) wide")
                for cell in row where cell != "." {
                    filled += 1
                    #expect(character.colors[cell] != nil, "\(character.id) \(pose) row \(index) uses unnamed colour \(cell)")
                }
            }
            #expect(filled >= 20, "\(character.id) \(pose) is nearly empty")
        }
        for (letter, value) in character.colors {
            #expect(letter != ".", "\(character.id)")
            #expect(value <= 0xFFFFFF, "\(character.id)")
        }
    }

    @Test("The raised pose is drawn only when it differs, and standing is the fallback")
    func poses() {
        let withPose = CharacterCatalog.all.filter { $0.raised != nil }
        #expect(withPose.count >= 13)
        for character in withPose {
            #expect(character.raised != character.standing, "\(character.id)")
            #expect(character.rows(raised: true) == character.raised)
            #expect(character.rows(raised: false) == character.standing)
        }
        let without = CharacterCatalog.all.first { $0.raised == nil }
        #expect(without?.rows(raised: true) == without?.standing)
    }

    @Test("A palette is read pair by pair and a malformed pair is dropped")
    func paletteParsing() {
        #expect(SessionCharacter.colors(from: "A:FF0000,B:00ff00") == ["A": 0xFF0000, "B": 0x00FF00])
        #expect(SessionCharacter.colors(from: "A:FF0000,BB:00FF00,C:XYZXYZ,D:FFF,E:0000FF") == ["A": 0xFF0000, "E": 0x0000FF])
        #expect(SessionCharacter.colors(from: "").isEmpty)
    }

    @Test("Only ids this version knows are kept, once each, in the order given")
    func knownIDs() {
        let cat = "animals.cat", dog = "animals.dog"
        #expect(CharacterCatalog.knownIDs(in: [dog, "from.a.newer.version", cat, dog, ""]) == [dog, cat])
        #expect(CharacterCatalog.knownIDs(in: []).isEmpty)
    }

    @Test("A project key is the clean folder path")
    func projectKeys() {
        #expect(ProjectKey.make("/Users/me/work/app/") == "/Users/me/work/app")
        #expect(ProjectKey.make("/Users/me/work/./app/../app") == "/Users/me/work/app")
        #expect(ProjectKey.make("  /Users/me/work/app\n") == "/Users/me/work/app")
        #expect(ProjectKey.make(nil) == nil)
        #expect(ProjectKey.make("   ") == nil)
        #expect(ProjectKey.displayName("/Users/me/work/app") == "app")
        // A folder that does not exist gets the same key as one that does:
        // the key is worked out from the text alone.
        #expect(ProjectKey.make("/no/such/folder/anywhere/") == "/no/such/folder/anywhere")
        #expect(ProjectKey.make("/private/tmp/work") == "/private/tmp/work")
    }

    @Test("A character is drawn on whole screen pixels at every size, on both kinds of display",
          arguments: [1.0, 2.0, 3.0], [17.0, 22.0, 24.0, 26.0, 31.0, 34.0, 38.0, 40.0])
    func spriteGeometry(scale: Double, size: Double) {
        let headroom = 2.0
        let canvas = CGSize(width: size, height: size + headroom * 2)
        let geometry = CharacterSpriteGeometry(canvas: canvas, headroom: headroom, displayScale: scale)
        let cells = Double(SessionCharacter.gridSize)
        func isWhole(_ points: Double) -> Bool { abs(points * scale - (points * scale).rounded()) < 0.000_1 }

        #expect(geometry.unit * scale >= 1)
        #expect(isWhole(geometry.unit), "unit \(geometry.unit)")
        #expect(isWhole(geometry.origin.x) && isWhole(geometry.origin.y) && isWhole(geometry.liftedY))
        // It fits its frame, and the lift stays inside the canvas.
        #expect(geometry.unit * cells <= size)
        #expect(geometry.origin.x >= 0 && geometry.origin.y >= 0)
        #expect(geometry.liftedY >= 0)
        #expect(geometry.origin.y + geometry.unit * cells <= canvas.height)
        // And it does lift, wherever there is any room above.
        if geometry.origin.y > 0 { #expect(geometry.liftedY < geometry.origin.y) }
    }

    @Test("A character is still drawn in a space smaller than itself")
    func tinySprite() {
        let geometry = CharacterSpriteGeometry(canvas: CGSize(width: 6, height: 6), headroom: 2, displayScale: 2)
        #expect(geometry.unit == 0.5)
    }
}
