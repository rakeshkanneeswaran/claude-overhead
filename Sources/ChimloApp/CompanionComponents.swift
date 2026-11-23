import ChimloCore
import SwiftUI

/// Building blocks for the companion window. Every colour comes from the
/// active theme palette so a theme switch restyles the whole window.

struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content
    @Environment(\.overheadPalette) private var palette

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.hairlineColor, lineWidth: 1)
        )
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var detail: String?
    var tint: Color?
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(tint ?? palette.textPrimary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.hairlineColor, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.textTertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }
}

struct Pill: View {
    let text: String
    var color: Color?
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color ?? palette.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background((color ?? palette.textSecondary).opacity(0.14))
            .clipShape(Capsule())
    }
}

/// A coloured dot plus a word for a session's state, so colour is never the
/// only signal.
struct MoodBadge: View {
    let mood: AvatarMood
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    var label: String {
        switch mood {
        case .working: "Working"
        case .waiting: "Needs permission"
        case .question: "Has a question"
        case .success: "Done"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    private var color: Color {
        switch mood {
        case .working: palette.working
        case .waiting: palette.permission
        case .question: palette.waiting
        case .success: palette.success
        case .failed: palette.failure
        case .idle: palette.textTertiary
        }
    }
}

struct HistoryStatusBadge: View {
    let status: HistoryStatus
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        Pill(text: status.displayName, color: color)
    }

    private var color: Color {
        switch status {
        case .running: palette.working
        case .waiting: palette.waiting
        case .completed: palette.success
        case .failed: palette.failure
        case .interrupted: palette.warning
        case .unknown: palette.textTertiary
        }
    }
}

/// A horizontal meter with a percentage, coloured by thresholds.
struct ThresholdMeter: View {
    let fraction: Double
    var attentionAt: Double = 0.7
    var criticalAt: Double = 0.9
    var width: CGFloat = 120
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(palette.hairlineColor)
                Capsule().fill(color).frame(width: max(4, width * min(1, max(0, fraction))))
            }
            .frame(width: width, height: 6)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent")
    }

    private var color: Color {
        if fraction >= criticalAt { return palette.failure }
        if fraction >= attentionAt { return palette.warning }
        return palette.success
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    @Environment(\.overheadPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

enum CompanionFormat {
    static func duration(_ seconds: TimeInterval?) -> String {
        // A date from a damaged history record can be centuries away; a
        // number that large cannot be made a whole number.
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 1e12 else { return "—" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    static func cost(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.2f", value)
    }

    static func tokens(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func relative(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func projectName(_ path: String?) -> String {
        guard let path else { return "Unknown project" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
