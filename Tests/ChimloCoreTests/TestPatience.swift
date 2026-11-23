/// How long a test waits. The rule, learnt from a CI runner so starved that a
/// third of a second of work took seven: a time limit in a test may only
/// bound the failure case, and must then be far beyond any delay a slow
/// machine can cause. Work that succeeds returns as soon as it is done, so a
/// long limit costs nothing; a short one fails at random.
enum Patience {
    /// For something expected to happen (an answer, a save, a cancellation).
    /// Reached only when it never does.
    static let expected: Duration = .seconds(60)
    static let expectedSeconds: Double = 60

    /// For something that must be cut short (a hung command, a connection
    /// nobody answers): how long it would take if it were left alone. A test
    /// then checks that it ended within `expected`, a fifth of this, so the
    /// two cannot be confused on any machine.
    static let leftAlone: Duration = .seconds(300)
    static let leftAloneSeconds: Double = 300
}
