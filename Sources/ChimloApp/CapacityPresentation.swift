import ChimloCore
import Foundation

enum CapacityLayout {
    static let detailsSpacing: CGFloat = 8
    /// The provider header and padding; each limit adds one row.
    static let detailsChromeHeight: CGFloat = 28
    static let rowHeight: CGFloat = 22

    /// Two rows make the original 72-point panel.
    static func detailsHeight(rows: Int) -> CGFloat {
        detailsChromeHeight + CGFloat(max(1, rows)) * rowHeight
    }

    static func disclosureHeight(rows: Int) -> CGFloat {
        detailsHeight(rows: rows) + detailsSpacing
    }
}

struct CapacityReading: Equatable {
    let window: CapacityWindowSnapshot?
    let isApproximate: Bool
    let lastUpdatedAt: Date?

    var remainingPercentage: Double? {
        window?.remainingPercentage
    }

    var usedPercentage: Double? {
        window?.usedPercentage
    }

    var isWarning: Bool {
        guard let remainingPercentage else { return false }
        return remainingPercentage <= CapacityPolicy.warningRemainingPercentage
    }

    var isExhausted: Bool {
        remainingPercentage == 0
    }
}
