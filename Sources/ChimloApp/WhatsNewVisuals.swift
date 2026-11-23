import AppKit
import ChimloCore
import SwiftUI

// The pictures on What's New cards. Each is drawn from data the release's
// notes carry, with the app's own components (the character sprite, the
// Claude mark, the run-state badge), so an illustration looks like the
// product and an older copy can draw a newer release's notes.

/// Where a release's pictures are read from.
enum WhatsNewAssets: Equatable {
    /// Beside the release's download.
    case remote(URL)
    /// Inside this app, for the notes it was built with.
    case bundled(URL)
    case none
}

/// One card's visual, or nothing when the card has none this copy can draw.
struct WhatsNewVisualView: View {
    let visual: ReleaseVisual
    let assets: WhatsNewAssets
    let reduceMotion: Bool

    var body: some View {
        switch visual {
        case let .sprites(sprites, caption):
            captioned(caption) { SpritesVisual(sprites: sprites, reduceMotion: reduceMotion) }
        case let .notch(rows, caption):
            // The notch hangs from the top of the stage, as it does from the
            // top of the screen.
            VStack(spacing: 0) {
                NotchPanelVisual(rows: rows, reduceMotion: reduceMotion)
                Spacer(minLength: 8)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SetupTheme.textTertiary)
                        .padding(.bottom, 14)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        case let .comparison(before, after):
            ComparisonVisual(before: before, after: after, reduceMotion: reduceMotion)
        case let .image(image):
            ReleaseImageView(image: image, assets: assets)
        case .unsupported:
            EmptyView()
        }
    }

    private func captioned(_ caption: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 12) {
            content()
            if let caption {
                Text(caption)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SetupTheme.textTertiary)
            }
        }
    }
}

// MARK: Characters

private struct SpritesVisual: View {
    let sprites: [ReleaseSprite]
    let reduceMotion: Bool

    /// One row up to six, then two rows.
    private var rows: [[ReleaseSprite]] {
        guard sprites.count > 6 else { return [sprites] }
        let firstRow = (sprites.count + 1) / 2
        return [Array(sprites.prefix(firstRow)), Array(sprites.dropFirst(firstRow))]
    }

    private var spriteSize: CGFloat {
        switch sprites.count {
        case ...4: 52
        case ...8: 44
        default: 36
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, sprite in
                        tile(sprite)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Characters: " + sprites.map(\.name).joined(separator: ", "))
    }

    private func tile(_ sprite: ReleaseSprite) -> some View {
        VStack(spacing: 5) {
            CharacterSprite(
                character: sprite.character,
                // Bobbing shows they are alive; standing still when motion is reduced.
                mood: reduceMotion ? .success : .working,
                size: spriteSize,
                reduceMotion: reduceMotion
            )
            Text(sprite.name)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(SetupTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: spriteSize + 28, height: spriteSize + 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SetupTheme.hairline, lineWidth: 1))
    }
}

// MARK: The notch

/// The open notch with a few session rows, as the real list shows them.
private struct NotchPanelVisual: View {
    let rows: [ReleaseNotchRow]
    let reduceMotion: Bool
    var width: CGFloat = 420

    var body: some View {
        VStack(spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                NotchRowVisual(row: row, reduceMotion: reduceMotion)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(width: width)
        .background(NotchExpandedIslandShape(lowerCut: 9).fill(Color.black))
        .overlay(alignment: .top) {
            // The camera, where the real notch has it.
            Circle()
                .fill(Color(white: 0.13))
                .frame(width: 6, height: 6)
                .overlay(Circle().fill(Color(white: 0.22)).frame(width: 2.5, height: 2.5))
                .padding(.top, 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The notch. " + rows.map(Self.spoken).joined(separator: " "))
    }

    static func spoken(_ row: ReleaseNotchRow) -> String {
        var parts = ["\(row.title): \(RunStateBadge.label(runState(row.status)))."]
        if let detail = row.detail { parts.append(detail + ".") }
        if let card = row.permission {
            parts.append("\(card.tool) asks to run \(card.request).")
            if let caption = card.caption { parts.append(caption + ".") }
        }
        return parts.joined(separator: " ")
    }

    static func runState(_ status: ReleaseRowStatus) -> SessionRunState {
        switch status {
        case .working: .running
        case .needsYou: .needsYou
        case .done: .recentlyCompleted
        case .failed: .failed
        case .idle: .older
        }
    }
}

private struct NotchRowVisual: View {
    let row: ReleaseNotchRow
    let reduceMotion: Bool

    private var mood: AvatarMood {
        switch row.status {
        case .working: .working
        case .needsYou: .waiting
        case .done: .success
        case .failed: .failed
        case .idle: .idle
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Group {
                    if let sprite = row.sprite {
                        CharacterSprite(character: sprite.character, mood: mood, size: 26, reduceMotion: reduceMotion)
                    } else {
                        ClaudeCodeMark(mood: mood, size: 26, reduceMotion: reduceMotion)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ChimloTheme.paper)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(row.status == .failed ? ChimloTheme.clayText : ChimloTheme.quietPaper)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                RunStateBadge(state: NotchPanelVisual.runState(row.status), reduceMotion: reduceMotion)
            }
            if let card = row.permission {
                permission(card)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ChimloTheme.raisedInk))
    }

    private func permission(_ card: ReleasePermissionCard) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(card.tool)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChimloTheme.paper)
                Text(card.request)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(ChimloTheme.quietPaper)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(Array(card.buttons.enumerated()), id: \.offset) { index, title in
                    let isLast = index == card.buttons.count - 1
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isLast ? Color.black : ChimloTheme.paper)
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isLast ? ChimloTheme.paper : ChimloTheme.paper.opacity(0.12))
                        )
                }
            }
            if let caption = card.caption {
                Text(caption)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(ChimloTheme.attention)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ChimloTheme.attentionInk))
    }
}

// MARK: Before and now

private struct ComparisonVisual: View {
    let before: ReleaseComparisonSide
    let after: ReleaseComparisonSide
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            side(before, tint: SetupTheme.textTertiary)
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SetupTheme.textTertiary)
                .frame(width: Self.rowWidth)
                .padding(.leading, Self.labelWidth + 12)
                .accessibilityHidden(true)
            side(after, tint: SetupTheme.success)
        }
    }

    private static let labelWidth: CGFloat = 62
    private static let rowWidth: CGFloat = 430

    /// A label, then the session rows as the notch lists them.
    private func side(_ side: ReleaseComparisonSide, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(side.label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(tint)
                .frame(width: Self.labelWidth, alignment: .trailing)
            VStack(spacing: 5) {
                ForEach(Array(side.rows.enumerated()), id: \.offset) { _, row in
                    NotchRowVisual(row: row, reduceMotion: reduceMotion)
                }
            }
            .padding(6)
            .frame(width: Self.rowWidth)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(side.label): " + side.rows.map(NotchPanelVisual.spoken).joined(separator: " "))
    }
}

// MARK: Pictures

/// Loads a release's pictures and hands back only bytes whose SHA-256 is the
/// one the signed notes pin. Anything else is treated as no picture.
@MainActor
final class WhatsNewImageStore: ObservableObject {
    static let shared = WhatsNewImageStore()

    private var images: [String: NSImage] = [:]

    func cached(_ image: ReleaseImage) -> NSImage? {
        image.sha256.flatMap { images[$0] }
    }

    func load(_ image: ReleaseImage, from assets: WhatsNewAssets) async -> NSImage? {
        if let cached = cached(image) { return cached }
        guard let hash = image.sha256, let data = await Self.data(for: image, from: assets),
              ReleaseImageCheck.accepts(data, for: image), let picture = NSImage(data: data) else { return nil }
        images[hash] = picture
        return picture
    }

    /// The same check without the network, for the release's render check.
    static func bundledPicture(_ image: ReleaseImage, in folder: URL) -> NSImage? {
        guard ReleaseImageCheck.isSafeFileName(image.file),
              let data = try? Data(contentsOf: folder.appendingPathComponent(image.file)),
              ReleaseImageCheck.accepts(data, for: image) else { return nil }
        return NSImage(data: data)
    }

    private static func data(for image: ReleaseImage, from assets: WhatsNewAssets) async -> Data? {
        switch assets {
        case .none:
            return nil
        case let .bundled(folder):
            guard ReleaseImageCheck.isSafeFileName(image.file) else { return nil }
            return try? Data(contentsOf: folder.appendingPathComponent(image.file))
        case let .remote(base):
            guard let url = ReleaseImageCheck.url(for: image, base: base) else { return nil }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpShouldHandleCookies = false
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            // Read as it arrives, and give up at the limit: an oversized
            // answer is never held in memory.
            guard let (bytes, response) = try? await session.bytes(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  response.expectedContentLength <= Int64(ReleaseImageCheck.maximumBytes) else { return nil }
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > ReleaseImageCheck.maximumBytes { return nil }
                }
            } catch {
                return nil
            }
            return data
        }
    }
}

private struct ReleaseImageView: View {
    let image: ReleaseImage
    let assets: WhatsNewAssets
    @State private var picture: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let picture = picture ?? WhatsNewImageStore.shared.cached(image) {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SetupTheme.hairline, lineWidth: 1))
                    .accessibilityLabel(image.alt)
            } else if failed {
                // No stand-in picture: say what it would have shown.
                Text(image.alt)
                    .font(.system(size: 12))
                    .foregroundStyle(SetupTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading a picture")
            }
        }
        .task(id: image.sha256) {
            picture = await WhatsNewImageStore.shared.load(image, from: assets)
            failed = picture == nil
        }
    }
}
