import Foundation

/// The eye button in the open notch: hide Claude Overhead outside the
/// physical notch, for fullscreen video and the like.
///
/// Hidden is its own state, not a layout. While it is on and the notch is
/// closed, the notch shrinks to the camera housing and draws nothing: no
/// character, no activity line, no signals, no glow. A click inside the
/// housing still opens it. Sessions are watched exactly as before.
///
/// The one exception is a request Claude is blocked on (a permission, a
/// question, a decision). Claude Code waits for that answer, so a hidden
/// notch never hides it: the closed notch shows its usual signal until the
/// request is answered, and whether the notch opens on it is Lock Mode's
/// decision, as it is without hiding (`NotchLockPolicy`).
public enum NotchVisibilityPolicy {
    public static func conceals(
        isHidden: Bool,
        isClosed: Bool,
        hasPendingOwnerRequest: Bool
    ) -> Bool {
        isHidden && isClosed && !hasPendingOwnerRequest
    }
}
