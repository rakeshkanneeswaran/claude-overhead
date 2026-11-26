import ChimloCore
import SwiftUI

/// Settings' completion sounds: "Same as the alert sound", then every sound
/// in `CompletionSoundLibrary` under its group. Each tile has its own play
/// button, so a sound can be heard before it is chosen; clicking the tile
/// chooses it (and plays it once). Value-driven, so it can be drawn with
/// made-up values (`SettingsRenderCheck`).
struct CompletionSoundPicker: View {
    /// The chosen id, or `CompletionSoundLibrary.sameAsAlert`.
    let selected: String
    /// The alert sound's name, for the first tile.
    let alertName: String
    let choose: (String) -> Void
    let preview: (String) -> Void

    @Environment(\.overheadPalette) private var palette

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 8)]

    /// A saved id this version does not know plays the alert sound, so the
    /// first tile is the one shown as chosen.
    private var effectiveSelection: String {
        CompletionSoundLibrary.sound(id: selected) == nil ? CompletionSoundLibrary.sameAsAlert : selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            tile(id: CompletionSoundLibrary.sameAsAlert, name: "Same as the alert sound", detail: alertName)
                .frame(maxWidth: 360, alignment: .leading)
            ForEach(CompletionSoundCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .textCase(.uppercase)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(CompletionSoundLibrary.sounds(in: category)) { sound in
                            tile(id: sound.id, name: sound.name, detail: nil)
                        }
                    }
                }
            }
        }
    }

    private func tile(id: String, name: String, detail: String?) -> some View {
        let isChosen = effectiveSelection == id
        return HStack(spacing: 10) {
            Button { preview(id) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(palette.accentColor.opacity(isChosen ? 0.9 : 0.16)))
                    .foregroundStyle(isChosen ? Color.white : palette.accentColor)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play \(name)")
            .accessibilityLabel("Play \(name)")

            Button { choose(id) } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 12.5, weight: isChosen ? .semibold : .regular))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        if let detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if isChosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(palette.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(detail.map { "\(name), \($0)" } ?? name)
            .accessibilityValue(isChosen ? "Chosen" : "")
            .accessibilityHint("Makes this the sound a finished turn plays.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isChosen ? palette.accentColor.opacity(0.12) : palette.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isChosen ? palette.accentColor : palette.hairlineColor, lineWidth: isChosen ? 1.5 : 1)
        )
    }
}
