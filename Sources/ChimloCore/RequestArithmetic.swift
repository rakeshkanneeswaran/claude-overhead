import Foundation

/// Arithmetic on values that arrive from outside the app (a helper's event
/// sequence, a request's expiry date). Swift traps on integer overflow, so a
/// hostile or mistaken value must be clamped, never trusted.
public enum RequestArithmetic {
    /// The longest a timer waits: ten years. Far below `Int64.max`
    /// nanoseconds, which the system's timers take as a signed delay.
    public static let maximumWaitSeconds: TimeInterval = 10 * 365 * 86_400

    /// The sequence after `last`, staying at `Int.max` instead of trapping.
    public static func nextSequence(after last: Int) -> Int {
        last == Int.max ? Int.max : last + 1
    }

    /// Nanoseconds to sleep for `seconds`: never negative, never more than
    /// `maximumWaitSeconds`, and zero for a value that is not a number.
    public static func sleepNanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN else { return 0 }
        let clamped = min(max(seconds, 0), maximumWaitSeconds)
        return UInt64(clamped * 1_000_000_000)
    }
}
