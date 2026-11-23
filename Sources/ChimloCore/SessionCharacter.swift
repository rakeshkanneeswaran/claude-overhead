import Foundation

/// The collections a character belongs to, in the order the pickers show them.
public enum CharacterWorld: String, CaseIterable, Codable, Sendable {
    case animals
    case elementals
    case fantasy
    case cyber

    public var displayName: String {
        switch self {
        case .animals: "Animals"
        case .elementals: "Elementals"
        case .fantasy: "Fantasy World"
        case .cyber: "Cyber World"
        }
    }
}

/// One character a session can wear in the notch: an original pixel drawing
/// on a 16 × 16 grid, with one letter per colour.
public struct SessionCharacter: Identifiable, Equatable, Sendable {
    /// Rows and columns of every character's grid.
    public static let gridSize = 16

    /// Stable across versions; it is what settings and assignments store.
    public let id: String
    public let name: String
    public let world: CharacterWorld
    /// The colour of each letter, as 0xRRGGBB.
    public let colors: [Character: UInt32]
    public let standing: [String]
    /// The "your turn" pose. Characters without one hop instead.
    public let raised: [String]?

    /// `palette` is "LETTER:RRGGBB" pairs separated by commas. A malformed
    /// pair is dropped, and its pixels are then simply not drawn.
    public init(
        id: String,
        name: String,
        world: CharacterWorld,
        palette: String,
        standing: [String],
        raised: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.world = world
        self.colors = Self.colors(from: palette)
        self.standing = standing
        self.raised = raised
    }

    /// The grid to draw: the raised pose when asked for and drawn.
    public func rows(raised wantsRaised: Bool) -> [String] {
        wantsRaised ? (raised ?? standing) : standing
    }

    static func colors(from palette: String) -> [Character: UInt32] {
        var result: [Character: UInt32] = [:]
        for pair in palette.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 1, parts[1].count == 6,
                  let letter = parts[0].first, let value = UInt32(parts[1], radix: 16) else { continue }
            result[letter] = value
        }
        return result
    }
}

/// Where a character's grid sits in its canvas, in whole screen pixels.
public struct CharacterSpriteGeometry: Equatable, Sendable {
    /// The side of one sprite pixel, in points.
    public let unit: CGFloat
    public let origin: CGPoint
    /// The top edge while the character is lifted one sprite pixel.
    public let liftedY: CGFloat

    public init(canvas: CGSize, headroom: CGFloat, displayScale: CGFloat) {
        let cells = CGFloat(SessionCharacter.gridSize)
        let scale = max(1, displayScale)
        let pixel = 1 / scale
        let fit = min(canvas.width, canvas.height - headroom * 2) / cells
        // The largest whole number of screen pixels that fits; never less
        // than one, so the character is always drawn.
        unit = max(pixel, (fit * scale).rounded(.down) / scale)
        let side = unit * cells
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.down) / scale }
        origin = CGPoint(x: snapped((canvas.width - side) / 2), y: snapped((canvas.height - side) / 2))
        liftedY = max(0, origin.y - unit)
    }
}

/// Every character the app ships. The artwork lives in CharacterArtwork.swift.
public enum CharacterCatalog {
    public static let all: [SessionCharacter] =
        animalsArtwork + elementalsArtwork + fantasyArtwork + cyberArtwork

    private static let byID: [String: SessionCharacter] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func character(id: String) -> SessionCharacter? { byID[id] }

    public static func characters(in world: CharacterWorld) -> [SessionCharacter] {
        all.filter { $0.world == world }
    }

    /// The ids that name a character in this version, in catalogue order.
    /// Settings written by another version may hold ids this one lacks.
    public static func knownIDs(in ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { byID[$0] != nil && seen.insert($0).inserted }
    }
}

/// The folder a session works in, as the key its project's settings are kept
/// under: the path with `.`/`..` and a trailing slash removed.
public enum ProjectKey {
    public static func make(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Naming it a directory keeps this to string work: without that,
        // Foundation looks the path up on disk, and this runs for every
        // listed session whenever the list is rebuilt.
        let standardized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        return standardized.isEmpty ? nil : standardized
    }

    /// The last folder name, for showing a project to the owner.
    public static func displayName(_ key: String) -> String {
        let name = URL(fileURLWithPath: key).lastPathComponent
        return name.isEmpty || name == "/" ? key : name
    }
}
