import ChimloCore
import Foundation

/// Something worth telling the owner about: a hook event, a context or
/// usage threshold, or a GitHub change.
struct AttentionEvent: Sendable {
    let kind: OverheadEventKind
    /// Identifies this occurrence for de-duplication.
    let key: String
    let sessionID: String?
    let title: String
    let body: String
}

/// Applies the notification policy to every event: it decides whether the
/// event sounds, expands the notch, or posts a macOS banner, remembers what
/// it delivered so repeats stay quiet, and keeps a short in-memory feed for
/// the companion window. Nothing here leaves the Mac.
@MainActor
final class AttentionRouter: ObservableObject {
    struct Delivered: Identifiable, Equatable {
        let id = UUID()
        let kind: OverheadEventKind
        let title: String
        let body: String
        let sessionID: String?
        let at: Date
    }

    @Published private(set) var recent: [Delivered] = []
    private var ledger = DeliveryLedger()
    private let notifier: SystemNotifier
    private let settings: () -> OverheadSettings
    static let recentLimit = 50

    init(notifier: SystemNotifier, settings: @escaping () -> OverheadSettings) {
        self.notifier = notifier
        self.settings = settings
    }

    func route(_ event: AttentionEvent, now: Date = .now) -> NotificationDecision {
        let decision = NotificationPolicy.decide(
            event.kind,
            key: event.key,
            settings: settings(),
            context: NotificationContext(now: now),
            ledger: &ledger
        )
        guard decision.showInNotch || decision.postSystemBanner || decision.playSound else {
            return decision
        }
        if event.kind.priority != .ambient {
            recent.insert(
                Delivered(kind: event.kind, title: event.title, body: event.body, sessionID: event.sessionID, at: now),
                at: 0
            )
            if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        }
        if decision.postSystemBanner {
            let identifier = "\(event.kind.rawValue).\(event.sessionID ?? event.key)"
            let notifier = notifier
            Task {
                await notifier.post(
                    title: event.title,
                    body: event.body,
                    identifier: identifier,
                    groupKey: decision.groupKey ?? event.sessionID
                )
            }
        }
        return decision
    }
}
