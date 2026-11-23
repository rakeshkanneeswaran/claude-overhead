import Foundation

/// Decides whether a "turn failed" report is about a turn the owner is
/// running.
///
/// Claude Code runs its StopFailure hook whenever a request ends in an API
/// error. That includes requests it makes by itself for a session that is
/// sitting idle (a recap for when you come back, a prompt suggestion), and the
/// hook input does not say which kind it was. Taken at face value, one bad
/// connection paints a session that finished an hour ago red, plays the
/// attention sound and opens the notch. Only a running turn can fail, so a
/// failure for a session with no turn running is dropped.
///
/// Hook helpers are separate short-lived processes and can arrive out of
/// order. A turn that fails at once may deliver its failure before the prompt
/// that started it, while the session still looks finished. The dropped
/// failure is therefore remembered for a moment: if an activity event made no
/// later than the failure arrives right behind it, the failure was real and is
/// delivered in its place.
public struct TurnFailureFilter: Sendable {
    /// How long after a dropped failure a late event may still claim it.
    /// Hook helpers are given two seconds to deliver.
    public static let lateArrivalWindow: TimeInterval = 3
    /// One remembered failure per session, and no more sessions than this.
    static let maximumRemembered = 64

    private struct DroppedFailure: Sendable {
        let event: AgentEvent
        let receivedAt: Date
    }

    private var dropped: [String: DroppedFailure] = [:]

    public init() {}

    var rememberedCount: Int { dropped.count }

    /// The event to apply, or nil when it should be dropped. `phase` is the
    /// session's phase before this event; nil when the session is unknown.
    public mutating func filter(
        _ event: AgentEvent,
        phase: SessionPhase?,
        receivedAt: Date
    ) -> AgentEvent? {
        switch event.kind {
        case .failed:
            // Waiting on the owner is not "running" here: Claude Code makes
            // no request of its own turn while a card is open, so a failure
            // then is one of its background requests.
            if phase == .working {
                dropped.removeValue(forKey: event.sessionID)
                return event
            }
            remember(event, receivedAt: receivedAt)
            return nil
        case .activity:
            guard let failure = dropped.removeValue(forKey: event.sessionID) else { return event }
            let elapsed = receivedAt.timeIntervalSince(failure.receivedAt)
            let arrivedRightBehind = elapsed >= 0 && elapsed <= Self.lateArrivalWindow
            // Event times cross the wire in whole seconds, so "no later"
            // includes the same second.
            let madeNoLater = event.timestamp <= failure.event.timestamp
            return arrivedRightBehind && madeNoLater ? failure.event : event
        case .sessionEnded:
            dropped.removeValue(forKey: event.sessionID)
            return event
        case .sessionStarted, .permissionRequested, .permissionResolved,
             .questionRequested, .questionResolved, .completed:
            return event
        }
    }

    public mutating func forget(sessionID: String) {
        dropped.removeValue(forKey: sessionID)
    }

    private mutating func remember(_ event: AgentEvent, receivedAt: Date) {
        dropped[event.sessionID] = DroppedFailure(event: event, receivedAt: receivedAt)
        guard dropped.count > Self.maximumRemembered,
              let oldest = dropped.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key else { return }
        dropped.removeValue(forKey: oldest)
    }
}
