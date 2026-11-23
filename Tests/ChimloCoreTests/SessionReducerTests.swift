import Foundation
import Testing
@testable import ChimloCore

@Suite("Session reducer")
struct SessionReducerTests {
    private let start = Date(timeIntervalSince1970: 100)

    @Test("Lifecycle applies in sequence")
    func lifecycleAppliesInSequence() {
        var reducer = SessionReducer()

        expectApplied(reducer.apply(event(sequence: 1, kind: .sessionStarted, detail: "Starting")))
        expectApplied(reducer.apply(event(sequence: 2, kind: .activity, detail: "Testing")))
        expectApplied(reducer.apply(event(sequence: 3, kind: .completed, detail: "Done")))

        let session = reducer.sessions["s1"]
        #expect(session?.phase == .completed)
        #expect(session?.detail == "Done")
        #expect(session?.lastSequence == 3)
    }

    @Test("A duplicate message ID is ignored")
    func duplicateMessageIsIgnored() {
        var reducer = SessionReducer()
        let message = event(sequence: 1, kind: .sessionStarted)

        expectApplied(reducer.apply(message))
        #expect(reducer.apply(message) == .ignoredDuplicate)
    }

    @Test("A stale per-session sequence is ignored")
    func staleSequenceIsIgnored() {
        var reducer = SessionReducer()
        expectApplied(reducer.apply(event(sequence: 2, kind: .sessionStarted)))
        #expect(reducer.apply(event(sequence: 1, kind: .activity)) == .ignoredStale)
        #expect(reducer.sessions["s1"]?.lastSequence == 2)
    }

    @Test("Approval is explicit and clears on resolution")
    func approvalMustBeExplicitAndClearsOnResolution() {
        var reducer = SessionReducer()
        expectApplied(reducer.apply(event(sequence: 1, kind: .sessionStarted)))
        let request = PendingRequest.approval(ApprovalRequest(id: "a1", summary: "Run tests?"))
        expectApplied(reducer.apply(event(sequence: 2, kind: .permissionRequested, request: request)))

        #expect(reducer.sessions["s1"]?.phase == .waitingForApproval)
        #expect(reducer.sessions["s1"]?.pendingRequest?.id == "a1")

        expectApplied(reducer.apply(event(sequence: 3, kind: .permissionResolved, decision: .deny)))
        #expect(reducer.sessions["s1"]?.phase == .working)
        #expect(reducer.sessions["s1"]?.pendingRequest == nil)
    }

    @Test("Questions resolve and failures clear pending input")
    func questionAndFailureTransitions() {
        var reducer = SessionReducer()
        expectApplied(reducer.apply(event(sequence: 1, kind: .sessionStarted)))
        let question = PendingRequest.question(
            AgentQuestion(id: "q1", prompt: "Which target?", options: ["Local", "Staging"])
        )
        expectApplied(reducer.apply(event(sequence: 2, kind: .questionRequested, request: question)))
        #expect(reducer.sessions["s1"]?.phase == .waitingForAnswer)

        expectApplied(reducer.apply(event(sequence: 3, kind: .questionResolved, decision: .answer("Local"))))
        expectApplied(reducer.apply(event(sequence: 4, kind: .failed, detail: "A focused check failed")))
        #expect(reducer.sessions["s1"]?.phase == .failed)
        #expect(reducer.sessions["s1"]?.pendingRequest == nil)
    }

    @Test("Optionless input signals do not become questions")
    func optionlessInputIsNotAQuestion() {
        var reducer = SessionReducer()
        expectApplied(reducer.apply(event(sequence: 1, kind: .sessionStarted)))
        let input = PendingRequest.question(
            AgentQuestion(id: "q1", prompt: "Continue in source app")
        )

        #expect(
            reducer.apply(event(sequence: 2, kind: .questionRequested, request: input))
                == .ignoredMissingSession
        )
        #expect(reducer.sessions["s1"]?.phase == .working)
        #expect(reducer.sessions["s1"]?.pendingRequest == nil)
    }

    @Test("Non-start events cannot invent a session")
    func nonStartEventCannotCreateSession() {
        var reducer = SessionReducer()
        #expect(reducer.apply(event(sequence: 1, kind: .activity)) == .ignoredMissingSession)
        #expect(reducer.sessions.isEmpty)
    }

    @Test("Discovered evidence merges without clearing actionable state")
    func discoveryPreservesActionableState() {
        var reducer = SessionReducer()
        expectApplied(reducer.apply(event(sequence: 1, kind: .sessionStarted)))
        let request = PendingRequest.approval(ApprovalRequest(id: "a1", summary: "Approve?"))
        expectApplied(reducer.apply(event(sequence: 2, kind: .permissionRequested, request: request)))

        reducer.merge(SessionCandidate(
            id: "s1",
            agent: .claude,
            title: "Recovered title",
            detail: "Recovered status",
            projectPath: "/tmp/project",
            jumpURL: URL(string: "https://example.com/sessions/s1"),
            phase: .completed,
            updatedAt: start.addingTimeInterval(20),
            evidence: .process
        ))

        #expect(reducer.sessions["s1"]?.phase == .waitingForApproval)
        #expect(reducer.sessions["s1"]?.pendingRequest?.id == "a1")
        #expect(reducer.sessions["s1"]?.jumpURL?.absoluteString == "https://example.com/sessions/s1")
    }

    @Test("A mid-session model switch follows the transcript, not a stale cache")
    func modelFollowsTranscript() {
        var reducer = SessionReducer()
        func candidate(model: String, evidence: SessionEvidenceSource) -> SessionCandidate {
            SessionCandidate(
                id: "s1",
                agent: .claude,
                title: "Project",
                detail: "Working",
                model: model,
                phase: .working,
                updatedAt: start,
                evidence: evidence
            )
        }

        reducer.merge(candidate(model: "claude-opus-5-5", evidence: .claudeTranscript))
        reducer.merge(candidate(model: "claude-sonnet-5-5", evidence: .claudeTranscript))
        #expect(reducer.sessions["s1"]?.model == "claude-sonnet-5-5")

        reducer.merge(candidate(model: "claude-opus-5-5", evidence: .cache))
        #expect(reducer.sessions["s1"]?.model == "claude-sonnet-5-5")
    }

    @Test("Claude Code's own title survives hook events, which only know the folder")
    func claudeTitleWins() {
        var reducer = SessionReducer()
        reducer.apply(event(sequence: 1, kind: .sessionStarted))
        #expect(reducer.sessions["s1"]?.title == "A session", "a hook names a session that has no title yet")
        reducer.merge(SessionCandidate(
            id: "s1", agent: .claude, title: "MacBook app ideas", titleKind: .task,
            detail: "Working", projectPath: "/Users/me/claude-overhead",
            phase: .working, updatedAt: start.addingTimeInterval(2), evidence: .claudeTranscript
        ))
        #expect(reducer.sessions["s1"]?.title == "MacBook app ideas")
        // Every later hook event carries the folder name as its title.
        reducer.apply(event(sequence: 3, kind: .activity, detail: "Running a command"))
        #expect(reducer.sessions["s1"]?.title == "MacBook app ideas")
        #expect(reducer.sessions["s1"]?.titleKind == .task)
        // Claude Code retitling the session is followed.
        reducer.merge(SessionCandidate(
            id: "s1", agent: .claude, title: "Claude Overhead notch app", titleKind: .task,
            detail: "Working", phase: .working, updatedAt: start.addingTimeInterval(4), evidence: .claudeTranscript
        ))
        #expect(reducer.sessions["s1"]?.title == "Claude Overhead notch app")
    }

    @Test("A session titled by Claude Code shows that title exactly; a folder stand-in keeps its context")
    func displayTitle() {
        #expect(SessionTitle.display(title: "MacBook app ideas", kind: .task, projectPath: "/Users/me/claude-overhead") == "MacBook app ideas")
        #expect(SessionTitle.display(title: "claude-overhead", kind: .workspace, projectPath: "/Users/me/claude-overhead") == "claude-overhead")
        #expect(SessionTitle.display(title: "Claude session", kind: .workspace, projectPath: "/Users/me/api") == "api · Claude session")
        #expect(SessionTitle.display(title: "Untitled session", kind: .workspace, projectPath: nil) == "Untitled session")
    }

    @Test("The demo command's script is deterministic")
    func demoScriptIsDeterministic() {
        let first = DemoScript.make()
        let second = DemoScript.make()

        #expect(first == second)
        #expect(first.map(\.offsetMilliseconds) == [0, 900, 1_800, 3_200, 4_200])
        #expect(first.last?.event.kind == .completed)
    }

    private func event(
        sequence: Int,
        kind: AgentEventKind,
        detail: String? = nil,
        request: PendingRequest? = nil,
        decision: UserDecision? = nil
    ) -> AgentEvent {
        AgentEvent(
            sessionID: "s1",
            sequence: sequence,
            kind: kind,
            agent: .claude,
            title: "A session",
            detail: detail,
            request: request,
            decision: decision,
            timestamp: start.addingTimeInterval(Double(sequence))
        )
    }

    private func expectApplied(_ result: ReductionResult) {
        guard case .applied = result else {
            Issue.record("Expected an applied event, got \(result)")
            return
        }
    }
}
