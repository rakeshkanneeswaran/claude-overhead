import Darwin

/// How long a piece of work kept this thread running: what the work costs,
/// not how long the machine took to get round to it.
///
/// A wall clock also counts the time a thread spent waiting for a core. On a
/// shared CI runner, with every suite running at once on three slow cores,
/// that wait is most of the total, so a wall-clock limit measured the runner
/// and failed at random. The time a thread actually ran does not grow while
/// it waits.
///
/// The work must not suspend (no `await`): after a suspension it may resume
/// on another thread.
enum ThreadCPUTime {
    static func measure(_ work: () -> Void) -> Duration {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        work()
        let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        return .nanoseconds(Int64(end >= start ? end - start : 0))
    }

}

/// A limit that means the same on every machine: how the cost of some work
/// grows with its input, with both sizes measured on the machine at hand.
enum CostGrowth {
    /// Ten times the input may cost up to this many times as much. Work that
    /// grows in step with its input costs about ten times as much (a sort, a
    /// little more); work that has turned quadratic costs a hundred.
    static let allowedForTenTimesTheInput = 40

    /// The cost of some work and of a tenth of it: the cheapest of a few
    /// runs each, taken turn about. Turn about, so that both get the same
    /// chances at a fast core and a warm cache; on a Mac a thread moves
    /// between cores that differ several times in speed, and a whole
    /// measured on a slow one against a tenth measured on a fast one would
    /// look like work that had stopped scaling.
    static func measure(rounds: Int = 3, whole: () -> Void, tenth: () -> Void) -> (whole: Duration, tenth: Duration) {
        var best = (whole: Duration.seconds(86_400), tenth: Duration.seconds(86_400))
        for _ in 0..<max(1, rounds) {
            best.whole = min(best.whole, ThreadCPUTime.measure(whole))
            best.tenth = min(best.tenth, ThreadCPUTime.measure(tenth))
        }
        return best
    }

    /// Whether `whole`, the cost of ten times the input that cost `tenth`,
    /// is in line with work that grows in step with its input.
    static func isInStep(whole: Duration, tenth: Duration) -> Bool {
        // A tenth too quick to time says nothing; it is not held against the work.
        guard tenth > .microseconds(5) else { return true }
        return whole < tenth * allowedForTenTimesTheInput
    }
}
