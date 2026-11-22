import Foundation
import Testing
@testable import ChimloCore

@Suite("Session history search")
struct SessionHistorySearchTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Every token must match some field; tokens may match different fields")
    func tokensAcrossFields() {
        var retries = record(id: "retries", title: "Add retries", offset: 10)
        retries.gitBranch = "feature/backoff"
        let docs = record(id: "docs", title: "Refresh docs", offset: 20)

        #expect(ids("retries backoff", in: [retries, docs]) == ["retries"])
        #expect(ids("  ADD   Feature/BACK  ", in: [retries, docs]) == ["retries"])
        #expect(ids("retries docs", in: [retries, docs]).isEmpty)
        #expect(ids("", in: [retries, docs]) == ["docs", "retries"])
    }

    @Test("Matching ignores case, diacritics and width")
    func foldedMatching() {
        let cafe = record(id: "cafe", title: "Café menu refactor", offset: 0)
        let plain = record(id: "plain", title: "Cafeteria", offset: -1)

        #expect(ids("CAFÉ menu", in: [cafe, plain]) == ["cafe"])
        #expect(ids("cafe", in: [cafe, plain]) == ["cafe", "plain"])
        #expect(ids("ｍｅｎｕ", in: [cafe, plain]) == ["cafe"])
    }

    @Test("All documented fields are searchable")
    func searchableFields() {
        var full = record(id: "full", title: "Untitled", offset: 0)
        full.projectPath = "/workspace/clients/orbit-api"
        full.projectName = "Orbit"
        full.model = "claude-opus-4-1"
        full.status = .interrupted
        full.latestUserPrompt = "Why is the cache cold?"
        full.latestAgentResponse = "The warmup job skipped tenants."
        full.agents = [HistoryAgent(id: "a1", type: "Explore", description: "Trace the warmup job")]
        full.pullRequests = [HistoryPullRequest(number: 42, url: "https://example.invalid/pr/42", repository: "example/orbit")]
        let other = record(id: "other", title: "Something else", offset: -5)

        for query in ["orbit-api", "orbit", "opus", "interrupted", "cache", "tenants", "explore", "trace", "#42", "example/orbit"] {
            #expect(ids(query, in: [full, other]) == ["full"], "query: \(query)")
        }
        // The parent directories of the project path are not searchable.
        #expect(ids("clients", in: [full, other]).isEmpty)
    }

    @Test("Structured filters combine with text and results are newest first")
    func filtersAndOrder() {
        var alpha = record(id: "alpha-done", title: "Ship alpha", offset: 30)
        alpha.status = .completed
        alpha.model = "claude-sonnet-4-5"
        var alphaFailed = record(id: "alpha-failed", title: "Ship alpha again", offset: 60)
        alphaFailed.status = .failed
        alphaFailed.model = "claude-opus-4-1"
        var beta = record(id: "beta", title: "Ship beta", offset: 90)
        beta.projectPath = "/workspace/beta"
        beta.status = .completed
        let all = [alpha, alphaFailed, beta]

        #expect(HistorySearch.filter(all, query: HistoryQuery(text: "ship")).map(\.id) == ["beta", "alpha-failed", "alpha-done"])
        #expect(HistorySearch.filter(all, query: HistoryQuery(statuses: [.completed])).map(\.id) == ["beta", "alpha-done"])
        #expect(HistorySearch.filter(all, query: HistoryQuery(models: ["claude-opus-4-1"])).map(\.id) == ["alpha-failed"])
        #expect(HistorySearch.filter(all, query: HistoryQuery(text: "ship", projectPath: "/workspace/alpha/")).map(\.id) == ["alpha-failed", "alpha-done"])

        // Date bounds match any overlap with the session's active span.
        let window = HistoryQuery(from: base.addingTimeInterval(50), to: base.addingTimeInterval(70))
        #expect(HistorySearch.filter(all, query: window).map(\.id) == ["beta", "alpha-failed"])
        #expect(HistorySearch.filter(all, query: HistoryQuery(to: base.addingTimeInterval(-61))).isEmpty)
    }

    @Test("Searching 10,000 records stays fast")
    func performance() {
        let records = (0..<10_000).map { index -> SessionHistoryRecord in
            var record = record(id: "session-\(index)", title: "Refactor module \(index) for résumé parsing", offset: TimeInterval(index))
            record.projectPath = "/workspace/project-\(index % 40)"
            record.projectName = "project-\(index % 40)"
            record.gitBranch = index.isMultiple(of: 7) ? "feature/needle-\(index)" : "main"
            record.model = index.isMultiple(of: 2) ? "claude-opus-4-1" : "claude-sonnet-4-5"
            record.latestUserPrompt = String(repeating: "Please look at the failing integration suite and explain. ", count: 4)
            record.latestAgentResponse = String(repeating: "I traced the failure to a stale fixture and updated it. ", count: 6)
            record.agents = [HistoryAgent(id: "agent-\(index)", type: "Explore", description: "Survey module \(index)")]
            return record
        }
        let query = HistoryQuery(text: "resume NEEDLE fixture", statuses: [.running])

        let clock = ContinuousClock()
        var matches: [SessionHistoryRecord] = []
        // Best of three, so one scheduling hiccup on a busy machine does not
        // fail the run. Shared CI runners are about twice as slow as a
        // developer Mac with every suite in parallel, so they get more room;
        // a quadratic search would still blow far past either budget.
        let elapsed = (0..<3).map { _ in
            clock.measure { matches = HistorySearch.filter(records, query: query) }
        }.min() ?? .seconds(60)
        let budget: Duration = ProcessInfo.processInfo.environment["CI"] == nil ? .milliseconds(500) : .milliseconds(1_500)

        #expect(matches.count == 1_429)
        #expect(matches.first?.id == "session-9996")
        #expect(elapsed < budget, "took \(elapsed), budget \(budget)")
    }

    private func ids(_ text: String, in records: [SessionHistoryRecord]) -> [String] {
        HistorySearch.filter(records, query: HistoryQuery(text: text)).map(\.id)
    }

    private func record(id: String, title: String, offset: TimeInterval) -> SessionHistoryRecord {
        SessionHistoryRecord(
            id: id,
            projectPath: "/workspace/alpha",
            projectName: "alpha",
            title: title,
            startedAt: base.addingTimeInterval(offset - 60),
            lastActivityAt: base.addingTimeInterval(offset),
            status: .running
        )
    }
}
