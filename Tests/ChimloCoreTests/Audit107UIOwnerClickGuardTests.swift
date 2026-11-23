import ChimloCore
import Foundation
import Testing

/// A click may approve or answer only the request the owner was looking at,
/// and only once the cards have held still long enough to be read.
@Suite("Audit 1.0.7 UI: clicks on request cards")
struct Audit107UIOwnerClickGuardTests {
    private let delay = OwnerClickGuard.armingDelay
    /// Just past the delay. Binary fractions make "exactly 0.4 s later"
    /// land a hair either side, and the rule is about a human click anyway.
    private var armed: TimeInterval { delay + 0.01 }
    private let first = UUID()
    private let second = UUID()

    @Test("A request that is not showing accepts no click")
    func unknownRequest() {
        var cards = OwnerClickGuard()
        #expect(!cards.accepts(first, at: 100))
        cards.presented(first, at: 100)
        #expect(!cards.accepts(second, at: 200))
    }

    @Test("A card accepts a click only after the arming delay")
    func armingDelay() {
        var cards = OwnerClickGuard()
        cards.presented(first, at: 100)
        #expect(!cards.accepts(first, at: 100))
        #expect(!cards.accepts(first, at: 100 + delay - 0.01))
        #expect(cards.accepts(first, at: 100 + armed))
        #expect(cards.accepts(first, at: 500))
    }

    @Test("A double-click on question 1 cannot answer question 2")
    func nextQuestionWaits() {
        var cards = OwnerClickGuard()
        cards.presented(first, step: 0, at: 100)
        #expect(cards.accepts(first, step: 0, at: 101))
        // The first click answered question 1; question 2 takes its place.
        cards.presented(first, step: 1, at: 101)
        // The second click, still carrying question 1, or already redrawn.
        #expect(!cards.accepts(first, step: 0, at: 101.15))
        #expect(!cards.accepts(first, step: 1, at: 101.15))
        #expect(cards.accepts(first, step: 1, at: 101 + armed))
        // A click for the old question never counts again.
        #expect(!cards.accepts(first, step: 0, at: 200))
    }

    @Test("A card that slides under the pointer when another is answered waits again")
    func cardsMovingReArmEveryCard() {
        var cards = OwnerClickGuard()
        cards.presented(first, at: 100)
        cards.presented(second, at: 100)
        #expect(cards.accepts(second, at: 110))
        // The first card is answered; the second moves up under the pointer.
        cards.removed(first, at: 110)
        #expect(!cards.accepts(second, at: 110.2))
        #expect(cards.accepts(second, at: 110 + armed))
    }

    @Test("A new card appearing makes the cards already showing wait again")
    func newCardReArmsOthers() {
        var cards = OwnerClickGuard()
        cards.presented(first, at: 100)
        cards.presented(second, at: 300)
        #expect(!cards.accepts(first, at: 300.1))
        #expect(!cards.accepts(second, at: 300.1))
        #expect(cards.accepts(first, at: 300 + armed))
        #expect(cards.accepts(second, at: 300 + armed))
    }

    @Test("The notch opening, or rows moving, makes every card wait again")
    func otherMovement() {
        var cards = OwnerClickGuard()
        cards.presented(first, at: 100)
        cards.cardsMoved(at: 400)
        #expect(!cards.accepts(first, at: 400 + delay - 0.01))
        #expect(cards.accepts(first, at: 400 + armed))
    }

    @Test("A card that left accepts nothing, and leaving twice changes nothing")
    func removedCard() {
        var cards = OwnerClickGuard()
        cards.presented(first, at: 100)
        cards.presented(second, at: 100)
        cards.removed(first, at: 200)
        #expect(!cards.accepts(first, at: 900))
        // Removing a request that is not showing must not re-arm the rest.
        cards.removed(first, at: 900)
        #expect(cards.accepts(second, at: 900))
    }

    @Test("A click that seems to come from before the card appeared is refused")
    func clickBeforePresentation() {
        var cards = OwnerClickGuard()
        cards.presented(first, at: 100)
        #expect(!cards.accepts(first, at: 50))
    }
}
