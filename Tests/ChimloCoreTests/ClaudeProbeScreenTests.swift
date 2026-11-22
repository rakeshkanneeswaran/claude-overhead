import Testing
@testable import ChimloCore

@Suite("Claude probe screen")
struct ClaudeProbeScreenTests {
    // Claude Code 2.1.280 draws the trust dialog with cursor moves between words.
    private let exitHighlighted = "\u{1B}[2G\u{1B}[38;2;177;185;249m❯\u{1B}[4GNo,\u{1B}[8Gexit\u{1B}[39m\n\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust\u{1B}[17Gthis\u{1B}[22Gfolder\n"
    private let trustHighlighted = "\u{1B}[4GNo,\u{1B}[8Gexit\n\u{1B}[2G❯\u{1B}[4GYes,\u{1B}[9GI\u{1B}[11Gtrust\u{1B}[17Gthis\u{1B}[22Gfolder\n"

    @Test("Text drawn with cursor moves still matches")
    func compactIgnoresCursorMoves() {
        let screen = ClaudeProbeScreen.compact("\u{1B}[2GQuick\u{1B}[8Gsafety\u{1B}[15Gcheck")
        #expect(screen == "quicksafetycheck")
    }

    @Test("The highlighted trust option is read from the newest marker")
    func readsHighlightedTrustOption() {
        #expect(ClaudeProbeScreen.highlightedTrustChoice(in: exitHighlighted) == .exit)
        #expect(ClaudeProbeScreen.highlightedTrustChoice(in: trustHighlighted) == .trust)
        #expect(ClaudeProbeScreen.highlightedTrustChoice(in: exitHighlighted + trustHighlighted) == .trust)
    }

    @Test("The main prompt after the dialog is not a trust option")
    func mainPromptEndsTheDialog() {
        let afterAccept = trustHighlighted + "\u{1B}[2G❯\u{1B}[4GTry\u{1B}[8G\"fix typecheck errors\""
        #expect(ClaudeProbeScreen.highlightedTrustChoice(in: afterAccept) == nil)
        #expect(ClaudeProbeScreen.highlightedTrustChoice(in: "no dialog here") == nil)
    }

    @Test("Each terminal query is answered once")
    func answersEachQueryOnce() {
        var answered: [String: Int] = [:]
        let startup = "\u{1B}[?u\u{1B}[c\u{1B}[>0q"
        #expect(ClaudeProbeScreen.pendingReplies(in: startup, answered: &answered).count == 3)
        #expect(ClaudeProbeScreen.pendingReplies(in: startup, answered: &answered).isEmpty)

        let later = startup + "\u{1B}[6n"
        #expect(ClaudeProbeScreen.pendingReplies(in: later, answered: &answered) == ["\u{1B}[1;1R"])
    }
}
