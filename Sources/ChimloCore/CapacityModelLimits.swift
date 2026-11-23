import Foundation

/// Per-model limits ("Current week (Fable)") come only from Claude Code's
/// `/usage` panel. The status line reports the 5-hour and weekly limits and
/// nothing per model, so a status-line reading must not wipe what the panel
/// found.
extension ProviderCapacitySnapshot {
    /// This reading plus the per-model limits `previous` knew and this one
    /// does not mention, until each of them resets. Limits this reading does
    /// report, and the limits across all models, are left exactly as read.
    public func keepingModelLimits(
        from previous: ProviderCapacitySnapshot?
    ) -> ProviderCapacitySnapshot {
        guard let previous, previous.provider == provider else { return self }
        let kept = previous.modelWindows.filter { earlier in
            !earlier.isExpired(at: observedAt)
                && !windows.contains { $0.isSameLimit(as: earlier) }
        }
        guard !kept.isEmpty else { return self }
        return ProviderCapacitySnapshot(
            provider: provider,
            windows: windows + kept,
            observedAt: observedAt
        )
    }

    /// The age that decides whether to ask Claude Code again: the oldest
    /// per-model limit when there is one, since a fresh status-line reading
    /// says nothing about those; otherwise this reading's own time.
    public var oldestLimitObservation: Date {
        modelWindows.map(\.observedAt).min().map { min($0, observedAt) } ?? observedAt
    }

    /// The same limits, dated by the oldest of them, for
    /// `CapacityPolicy.shouldProbeClaudeUsage`.
    public var datedByOldestLimit: ProviderCapacitySnapshot {
        ProviderCapacitySnapshot(provider: provider, windows: windows, observedAt: oldestLimitObservation)
    }
}
