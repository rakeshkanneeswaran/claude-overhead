import Foundation

/// Reads the Claude Code terminal screen that the usage probe drives.
///
/// Claude Code 2.1.280 draws words apart with cursor moves rather than spaces
/// (`Quick⟨move⟩safety⟨move⟩check`), so every match here compares a compact
/// form with control sequences, whitespace, and case removed.
public enum ClaudeProbeScreen {
    public enum TrustChoice: Equatable, Sendable {
        case trust
        case exit
    }

    /// Terminal capability queries Claude Code sends while starting, with the
    /// answers a basic xterm gives. Claude ignores keyboard input until they
    /// are answered, and an unanswered query can make it read the Escape that
    /// starts an arrow key as "Esc to cancel".
    static let queryReplies: [(query: String, reply: String)] = [
        ("\u{1B}[6n", "\u{1B}[1;1R"),
        ("\u{1B}[c", "\u{1B}[?62;22c"),
        ("\u{1B}[>0q", "\u{1B}P>|xterm(388)\u{1B}\\"),
        ("\u{1B}[?u", "\u{1B}[?0u"),
    ]

    public static func compact(_ output: String) -> String {
        ProviderCapacityParser.strippingTerminalControlSequences(output)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    /// Replies owed for queries that appeared since the last call. `answered`
    /// counts the occurrences already replied to, so each query is answered once.
    public static func pendingReplies(
        in output: String,
        answered: inout [String: Int]
    ) -> [String] {
        var replies: [String] = []
        for (query, reply) in queryReplies {
            let seen = output.components(separatedBy: query).count - 1
            let owed = seen - answered[query, default: 0]
            if owed > 0 {
                replies.append(contentsOf: repeatElement(reply, count: owed))
                answered[query] = seen
            }
        }
        return replies
    }

    /// The trust dialog option currently highlighted, or nil when the dialog is
    /// not the newest thing on screen. Claude 2.1.280 highlights "No, exit"
    /// first, so pressing Enter blindly quits the probe.
    public static func highlightedTrustChoice(in output: String) -> TrustChoice? {
        let screen = compact(output)
        guard let marker = screen.range(of: "❯", options: .backwards) else { return nil }
        let option = screen[marker.upperBound...]
        if option.hasPrefix("yes,itrustthisfolder") { return .trust }
        if option.hasPrefix("no,exit") { return .exit }
        return nil
    }
}
