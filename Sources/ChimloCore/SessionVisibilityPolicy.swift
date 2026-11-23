import Foundation

public enum SessionVisibilityPolicy {
    public static let activityLifetime: TimeInterval = 2 * 60 * 60

    public static func wasActiveRecently(
        updatedAt: Date,
        now: Date = .now
    ) -> Bool {
        updatedAt > now.addingTimeInterval(-activityLifetime)
    }

    public static func shouldDisplay(
        title: String,
        titleKind: SessionTitleKind,
        hasActionableRequest: Bool,
        hasConversationPreview: Bool = false
    ) -> Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        // Workspace basenames alone are discovery fallbacks, not session
        // titles. A transient conversation preview is stronger evidence of a
        // real session, while remaining excluded from Claude Overhead's saved registry.
        return titleKind == .task
            || hasActionableRequest
            || hasConversationPreview
    }
}
