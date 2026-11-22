import Foundation
import Testing
@testable import ChimloCore

@Suite("Attention rules")
struct AttentionRulesTests {
    @Test("A threshold warns once per crossing and re-arms below it")
    func thresholdCrossing() {
        var tracker = ThresholdCrossingTracker()
        let first = tracker.crossed("s1", value: 0.5, threshold: 0.7)
        let crossing = tracker.crossed("s1", value: 0.72, threshold: 0.7)
        let hovering = tracker.crossed("s1", value: 0.8, threshold: 0.7)
        let compacted = tracker.crossed("s1", value: 0.3, threshold: 0.7)
        let refilled = tracker.crossed("s1", value: 0.75, threshold: 0.7)
        #expect(!first)
        #expect(crossing)
        #expect(!hovering)
        #expect(!compacted)
        #expect(refilled)
    }

    @Test("Sessions are tracked independently, and NaN never warns")
    func thresholdKeysAndNaN() {
        var tracker = ThresholdCrossingTracker()
        let a = tracker.crossed("a", value: 0.9, threshold: 0.7)
        let b = tracker.crossed("b", value: 0.9, threshold: 0.7)
        let nan = tracker.crossed("c", value: .nan, threshold: 0.7)
        #expect(a && b)
        #expect(!nan)
        tracker.forget("a")
        let again = tracker.crossed("a", value: 0.9, threshold: 0.7)
        #expect(again)
    }

    @Test("Next and previous wrap around and survive a changed list")
    func selectionCycle() {
        let ids = ["a", "b", "c"]
        #expect(SelectionCycle.next(in: ids, current: nil, offset: 1) == "a")
        #expect(SelectionCycle.next(in: ids, current: nil, offset: -1) == "c")
        #expect(SelectionCycle.next(in: ids, current: "a", offset: 1) == "b")
        #expect(SelectionCycle.next(in: ids, current: "c", offset: 1) == "a")
        #expect(SelectionCycle.next(in: ids, current: "a", offset: -1) == "c")
        #expect(SelectionCycle.next(in: ids, current: "b", offset: -7) == "a")
        #expect(SelectionCycle.next(in: ids, current: "gone", offset: 1) == "a")
        #expect(SelectionCycle.next(in: [], current: "a", offset: 1) == nil)
    }

    @Test("A moved session's newest transcript wins over its older copy")
    func transcriptSource() {
        let old = TranscriptSourcePreference.Source(path: "/old/s.jsonl", modifiedAt: Date(timeIntervalSince1970: 100))
        let new = TranscriptSourcePreference.Source(path: "/new/s.jsonl", modifiedAt: Date(timeIntervalSince1970: 200))
        #expect(TranscriptSourcePreference.shouldReplace(nil, with: old))
        #expect(TranscriptSourcePreference.shouldReplace(old, with: new))
        #expect(!TranscriptSourcePreference.shouldReplace(new, with: old))
        // The same file always refreshes, even if its clock looks older.
        let sameFileEarlier = TranscriptSourcePreference.Source(path: "/new/s.jsonl", modifiedAt: Date(timeIntervalSince1970: 150))
        #expect(TranscriptSourcePreference.shouldReplace(new, with: sameFileEarlier))
    }

    @Test("Notch states map to history statuses without inventing outcomes")
    func historyStatus() {
        #expect(SessionActivityState.working.historyStatus == .running)
        #expect(SessionActivityState.waitingForPermission.historyStatus == .waiting)
        #expect(SessionActivityState.waitingForAnswer.historyStatus == .waiting)
        #expect(SessionActivityState.finished.historyStatus == .completed)
        #expect(SessionActivityState.failed.historyStatus == .failed)
        #expect(SessionActivityState.idle.historyStatus == .unknown)
    }

    @Test("GitHub changes map to notification kinds; a plain close is silent")
    func gitHubKinds() {
        #expect(GitHubEvent.ciFailed(prID: "o/r#1").overheadKind == .githubCIFailed)
        #expect(GitHubEvent.ciPassed(prID: "o/r#1").overheadKind == .githubCIPassed)
        #expect(GitHubEvent.reviewRequested(prID: "o/r#1").overheadKind == .githubReviewRequested)
        #expect(GitHubEvent.changesRequested(prID: "o/r#1").overheadKind == .githubChangesRequested)
        #expect(GitHubEvent.approved(prID: "o/r#1").overheadKind == .githubApproved)
        #expect(GitHubEvent.newComments(prID: "o/r#1", count: 2).overheadKind == .githubNewComments)
        #expect(GitHubEvent.merged(prID: "o/r#1").overheadKind == .githubMerged)
        #expect(GitHubEvent.closed(prID: "o/r#1").overheadKind == nil)
    }

    @Test("Every GitHub kind the model emits is one the policy treats as GitHub")
    func gitHubKindsAreGitHub() {
        let events: [GitHubEvent] = [
            .ciFailed(prID: "x"), .ciPassed(prID: "x"), .reviewRequested(prID: "x"),
            .changesRequested(prID: "x"), .approved(prID: "x"), .newComments(prID: "x", count: 1), .merged(prID: "x"),
        ]
        for event in events {
            #expect(event.overheadKind?.isGitHub == true)
        }
    }
}
