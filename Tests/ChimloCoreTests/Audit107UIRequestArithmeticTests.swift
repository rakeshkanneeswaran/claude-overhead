import ChimloCore
import Foundation
import Testing

/// Values from outside the app (an event sequence from `overhead emit`, a
/// request's expiry date) must never trap the app.
@Suite("Audit 1.0.7 UI: arithmetic on outside values")
struct Audit107UIRequestArithmeticTests {
    @Test("The next sequence counts up and stops at the largest integer")
    func nextSequence() {
        #expect(RequestArithmetic.nextSequence(after: 0) == 1)
        #expect(RequestArithmetic.nextSequence(after: 41) == 42)
        #expect(RequestArithmetic.nextSequence(after: Int.max - 1) == Int.max)
        #expect(RequestArithmetic.nextSequence(after: Int.max) == Int.max)
        #expect(RequestArithmetic.nextSequence(after: Int.min) == Int.min + 1)
    }

    @Test("A wait is never negative and never more than the cap")
    func sleepIsClamped() {
        #expect(RequestArithmetic.sleepNanoseconds(for: 1.5) == 1_500_000_000)
        #expect(RequestArithmetic.sleepNanoseconds(for: 0) == 0)
        #expect(RequestArithmetic.sleepNanoseconds(for: -30) == 0)
        #expect(RequestArithmetic.sleepNanoseconds(for: -.infinity) == 0)
        #expect(RequestArithmetic.sleepNanoseconds(for: .nan) == 0)
        let cap = UInt64(RequestArithmetic.maximumWaitSeconds * 1_000_000_000)
        #expect(RequestArithmetic.sleepNanoseconds(for: .infinity) == cap)
        #expect(RequestArithmetic.sleepNanoseconds(for: .greatestFiniteMagnitude) == cap)
        #expect(RequestArithmetic.sleepNanoseconds(for: Date.distantFuture.timeIntervalSinceNow) == cap)
    }

    @Test("The cap fits the signed delay the system's timers take")
    func capFitsASignedDelay() {
        #expect(RequestArithmetic.sleepNanoseconds(for: .infinity) <= UInt64(Int64.max))
    }
}
