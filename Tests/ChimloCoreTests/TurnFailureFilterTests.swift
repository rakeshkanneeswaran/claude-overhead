import Foundation
import Testing
@testable import ChimloCore

/// Through 1.0.8 every StopFailure hook marked its session failed. Claude Code
/// also runs that hook for requests it makes by itself while a session is
/// idle, so one bad connection turned a session that had finished an hour
/// earlier red, with the attention sound and an opening notch.
@Suite("Turn failures: only a running turn can fail")
struct TurnFailureFilterTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func event(
        _ kind: AgentEventKind,
        session: String = "s1",
        at seconds: TimeInterval = 0
    ) -> AgentEvent {
        AgentEvent(
            sessionID: session,
            sequence: 0,
            kind: kind,
            agent: .claude,
            detail: kind == .failed ? "Turn stopped" : "Thinking",
            timestamp: base.addingTimeInterval(seconds)
        )
    }

    private static func received(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    @Test("A failure during a running turn is delivered")
    func runningTurnFails() {
        var filter = TurnFailureFilter()
        let failure = Self.event(.failed, at: 5)
        #expect(filter.filter(failure, phase: .working, receivedAt: Self.received(5)) == failure)
        #expect(filter.rememberedCount == 0)
    }

    @Test("A failure with no turn running is dropped", arguments: [
        SessionPhase.completed, .failed, .waitingForApproval, .waitingForAnswer,
    ])
    func noTurnRunning(phase: SessionPhase) {
        var filter = TurnFailureFilter()
        #expect(filter.filter(Self.event(.failed), phase: phase, receivedAt: Self.base) == nil)
    }

    @Test("A failure for a session the app has never seen is dropped")
    func unknownSession() {
        var filter = TurnFailureFilter()
        #expect(filter.filter(Self.event(.failed), phase: nil, receivedAt: Self.base) == nil)
    }

    @Test("A turn that fails at once is still reported when its prompt arrives second")
    func failureArrivesBeforeItsPrompt() {
        var filter = TurnFailureFilter()
        // Made in this order: prompt at 10.0, failure at 10.4. Delivered the
        // other way round, while the session still looks finished.
        let failure = Self.event(.failed, at: 10)
        let prompt = Self.event(.activity, at: 10)
        #expect(filter.filter(failure, phase: .completed, receivedAt: Self.received(10.45)) == nil)
        #expect(filter.filter(prompt, phase: .completed, receivedAt: Self.received(10.5)) == failure)
        // Claimed once: the next activity is a new turn.
        let next = Self.event(.activity, at: 10)
        #expect(filter.filter(next, phase: .failed, receivedAt: Self.received(10.6)) == next)
    }

    @Test("A prompt sent after a dropped failure starts a normal turn")
    func laterPromptIsANewTurn() {
        var filter = TurnFailureFilter()
        #expect(filter.filter(Self.event(.failed, at: 10), phase: .completed, receivedAt: Self.received(10)) == nil)
        // Two minutes later the owner types a message.
        let prompt = Self.event(.activity, at: 130)
        #expect(filter.filter(prompt, phase: .completed, receivedAt: Self.received(130)) == prompt)
        #expect(filter.rememberedCount == 0)
    }

    @Test("A dropped failure is not claimed by an event made after it, or one arriving late")
    func notClaimedWithoutBothSigns() {
        var filter = TurnFailureFilter()
        // Made after the failure, even though it arrives right behind it.
        #expect(filter.filter(Self.event(.failed, at: 10), phase: .completed, receivedAt: Self.received(10)) == nil)
        let madeLater = Self.event(.activity, at: 11)
        #expect(filter.filter(madeLater, phase: .completed, receivedAt: Self.received(11)) == madeLater)

        // Made no later, but arriving long after any hook helper would.
        #expect(filter.filter(Self.event(.failed, at: 20), phase: .completed, receivedAt: Self.received(20)) == nil)
        let late = Self.event(.activity, at: 20)
        let afterWindow = Self.received(20 + TurnFailureFilter.lateArrivalWindow + 0.1)
        #expect(filter.filter(late, phase: .completed, receivedAt: afterWindow) == late)

        // A clock that went backwards claims nothing.
        #expect(filter.filter(Self.event(.failed, at: 30), phase: .completed, receivedAt: Self.received(30)) == nil)
        let earlier = Self.event(.activity, at: 30)
        #expect(filter.filter(earlier, phase: .completed, receivedAt: Self.received(29)) == earlier)
    }

    @Test("Sessions do not claim each other's failures")
    func sessionsAreSeparate() {
        var filter = TurnFailureFilter()
        #expect(filter.filter(Self.event(.failed, session: "a", at: 10), phase: .completed, receivedAt: Self.received(10)) == nil)
        let other = Self.event(.activity, session: "b", at: 10)
        #expect(filter.filter(other, phase: .completed, receivedAt: Self.received(10.1)) == other)
        #expect(filter.rememberedCount == 1)
    }

    @Test("Other events pass through untouched, and an ended session is forgotten")
    func otherEvents() {
        var filter = TurnFailureFilter()
        for kind in [AgentEventKind.sessionStarted, .completed, .permissionResolved, .questionResolved] {
            let event = Self.event(kind)
            #expect(filter.filter(event, phase: .completed, receivedAt: Self.base) == event)
        }
        #expect(filter.filter(Self.event(.failed), phase: .completed, receivedAt: Self.base) == nil)
        #expect(filter.rememberedCount == 1)
        let ended = Self.event(.sessionEnded)
        #expect(filter.filter(ended, phase: .completed, receivedAt: Self.base) == ended)
        #expect(filter.rememberedCount == 0)

        #expect(filter.filter(Self.event(.failed), phase: .completed, receivedAt: Self.base) == nil)
        filter.forget(sessionID: "s1")
        #expect(filter.rememberedCount == 0)
    }

    @Test("What is remembered stays bounded, oldest dropped first")
    func bounded() {
        var filter = TurnFailureFilter()
        let total = TurnFailureFilter.maximumRemembered + 20
        for index in 0..<total {
            _ = filter.filter(
                Self.event(.failed, session: "s\(index)", at: Double(index)),
                phase: .completed,
                receivedAt: Self.received(Double(index))
            )
        }
        #expect(filter.rememberedCount == TurnFailureFilter.maximumRemembered)
        // The first session's failure is gone; the last one's is still there.
        let first = Self.event(.activity, session: "s0", at: 0)
        #expect(filter.filter(first, phase: .completed, receivedAt: Self.received(0.1)) == first)
        let last = Self.event(.activity, session: "s\(total - 1)", at: Double(total - 1))
        let claimed = filter.filter(last, phase: .completed, receivedAt: Self.received(Double(total - 1) + 0.1))
        #expect(claimed?.kind == .failed)
    }

    // MARK: With the reducer, as the app uses it

    private static func apply(
        _ events: [(AgentEvent, TimeInterval)],
        to reducer: inout SessionReducer,
        filter: inout TurnFailureFilter
    ) {
        for (event, receivedAt) in events {
            guard let kept = filter.filter(
                event,
                phase: reducer.sessions[event.sessionID]?.phase,
                receivedAt: received(receivedAt)
            ) else { continue }
            // The app numbers hook events in the order it accepts them.
            let next = (reducer.sessions[kept.sessionID]?.lastSequence ?? 0) + 1
            reducer.apply(AgentEvent(
                sessionID: kept.sessionID,
                sequence: next,
                kind: kept.kind,
                agent: kept.agent,
                detail: kept.detail,
                timestamp: kept.timestamp
            ))
        }
    }

    @Test("A finished session stays finished when a background request fails")
    func finishedSessionStaysFinished() {
        var reducer = SessionReducer()
        var filter = TurnFailureFilter()
        Self.apply([
            (Self.event(.sessionStarted, at: 0), 0),
            (Self.event(.activity, at: 1), 1),
            (Self.event(.completed, at: 60), 60),
            // 54 minutes later, with nobody typing.
            (Self.event(.failed, at: 3_300), 3_300),
        ], to: &reducer, filter: &filter)
        #expect(reducer.sessions["s1"]?.phase == .completed)
    }

    @Test("A turn that fails is shown as failed, in either delivery order")
    func realFailureInBothOrders() {
        var inOrder = SessionReducer()
        var filter = TurnFailureFilter()
        Self.apply([
            (Self.event(.sessionStarted, at: 0), 0),
            (Self.event(.completed, at: 60), 60),
            (Self.event(.activity, at: 100), 100.0),
            (Self.event(.failed, at: 100), 100.4),
        ], to: &inOrder, filter: &filter)
        #expect(inOrder.sessions["s1"]?.phase == .failed)
        #expect(inOrder.sessions["s1"]?.detail == "Turn stopped")

        var reversed = SessionReducer()
        filter = TurnFailureFilter()
        Self.apply([
            (Self.event(.sessionStarted, at: 0), 0),
            (Self.event(.completed, at: 60), 60),
            (Self.event(.failed, at: 100), 100.4),
            (Self.event(.activity, at: 100), 100.45),
        ], to: &reversed, filter: &filter)
        #expect(reversed.sessions["s1"]?.phase == .failed)
    }

    // MARK: The app target, which has no tests of its own

    @Test("The app filters hook events before it does anything else with them")
    func appFiltersFirst() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ChimloApp/ApplicationModel.swift")
        let model = try String(contentsOf: path, encoding: .utf8)
        let start = try #require(model.range(of: "private func receiveLiveEvent("))
        let rest = model[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])

        let filtered = try #require(body.range(of: "turnFailureFilter.filter("))
        let endsRequests = try #require(body.range(of: "OwnerInteractionLifetime.endsPendingRequests"))
        let consumed = try #require(body.range(of: "consume("))
        #expect(filtered.lowerBound < endsRequests.lowerBound)
        #expect(filtered.lowerBound < consumed.lowerBound)
        #expect(body.contains("phase: reducer.sessions[reported.sessionID]?.phase"))
        // Only hook events, which carry no sequence of their own.
        #expect(body.contains("if reported.sequence == 0"))
        // A removed session takes its remembered failure with it.
        #expect(model.contains("turnFailureFilter.forget(sessionID: sessionID)"))
    }
}
