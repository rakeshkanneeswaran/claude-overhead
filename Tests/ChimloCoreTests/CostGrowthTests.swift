import Darwin
import Testing

/// The speed tests no longer hold work to a wall-clock limit, which failed at
/// random on a busy CI runner. They hold it to how its cost grows instead.
/// These prove that check still catches what a speed test is for.
@Suite("Speed checks that do not depend on the machine")
struct CostGrowthTests {
    @Test("Ten times the input for about ten times the cost passes; a hundred times does not")
    func rule() {
        #expect(CostGrowth.isInStep(whole: .milliseconds(100), tenth: .milliseconds(10)))
        #expect(CostGrowth.isInStep(whole: .milliseconds(390), tenth: .milliseconds(10)))
        #expect(!CostGrowth.isInStep(whole: .milliseconds(400), tenth: .milliseconds(10)))
        #expect(!CostGrowth.isInStep(whole: .seconds(1), tenth: .milliseconds(10)))
        // A tenth too quick to time is no evidence against the work.
        #expect(CostGrowth.isInStep(whole: .seconds(1), tenth: .microseconds(2)))
    }

    @Test("Measured on this machine: steady work passes, work that has turned quadratic is caught")
    func tellsSteadyFromQuadratic() {
        func steady(_ count: Int) -> Int {
            var sum = 0
            for index in 0..<count { sum &+= (index &* 31) % 7 }
            return sum
        }
        func quadratic(_ count: Int) -> Int {
            var sum = 0
            for outer in 0..<count {
                for inner in 0..<count { sum &+= (outer ^ inner) & 3 }
            }
            return sum
        }
        var sink = 0
        let linear = CostGrowth.measure(whole: { sink &+= steady(2_000_000) }, tenth: { sink &+= steady(200_000) })
        #expect(CostGrowth.isInStep(whole: linear.whole, tenth: linear.tenth), "\(linear.whole) against \(linear.tenth)")
        let runaway = CostGrowth.measure(whole: { sink &+= quadratic(3_000) }, tenth: { sink &+= quadratic(300) })
        #expect(!CostGrowth.isInStep(whole: runaway.whole, tenth: runaway.tenth), "\(runaway.whole) against \(runaway.tenth)")
        #expect(sink != .min)
    }

    @Test("CPU time counts running, not waiting")
    func cpuTimeIgnoresWaiting() {
        // A thread asleep is not running: a quarter of a second of sleep
        // costs next to nothing, where a wall clock would count all of it.
        let asleep = ThreadCPUTime.measure { usleep(250_000) }
        #expect(asleep < .milliseconds(50), "\(asleep)")
    }
}
