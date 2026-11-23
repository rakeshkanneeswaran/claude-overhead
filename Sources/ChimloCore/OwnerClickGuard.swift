import Foundation

/// Decides whether a click on a permission, question or decision card may
/// act. A click counts only when it names the request (and question step)
/// that is showing now, and only once the cards have held still long enough
/// to be read: a double-click, or a click already on its way when a card
/// appears or slides under the pointer, must never approve or answer
/// something the owner has not had time to see.
///
/// Times are monotonic seconds (`ProcessInfo.systemUptime`), so a wall-clock
/// change can neither arm a card early nor keep it disarmed.
public struct OwnerClickGuard: Sendable {
    /// How long the cards must be unchanged before a click counts.
    public static let armingDelay: TimeInterval = 0.4

    private struct Card: Sendable {
        var step: Int
        var presentedAt: TimeInterval
    }

    private var cards: [UUID: Card] = [:]
    /// The last time any card appeared, changed step or left. Each of those
    /// moves the other cards, so every card waits again.
    private var lastChange: TimeInterval?

    public init() {}

    /// A card appeared, or moved on to its next question.
    public mutating func presented(_ request: UUID, step: Int = 0, at now: TimeInterval) {
        cards[request] = Card(step: step, presentedAt: now)
        lastChange = now
    }

    /// A card left the notch, however it ended.
    public mutating func removed(_ request: UUID, at now: TimeInterval) {
        guard cards.removeValue(forKey: request) != nil else { return }
        lastChange = now
    }

    /// The cards moved for another reason, such as the notch opening.
    public mutating func cardsMoved(at now: TimeInterval) {
        lastChange = now
    }

    /// Whether a click made at `now` on the card for `request`, showing
    /// question `step`, may act.
    public func accepts(_ request: UUID, step: Int = 0, at now: TimeInterval) -> Bool {
        guard let card = cards[request], card.step == step else { return false }
        let settledAt = max(card.presentedAt, lastChange ?? card.presentedAt)
        return now - settledAt >= Self.armingDelay
    }
}
