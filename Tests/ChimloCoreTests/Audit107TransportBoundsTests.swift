import Foundation
import Testing
@testable import ChimloCore

/// State that would otherwise grow, or numbers that would otherwise
/// overflow, for as long as the app runs.
@Suite("Audit 107: bounded reducer, scanner and transcript caches")
struct Audit107TransportBoundsTests {
    // MARK: Reducer

    @Test("The reducer remembers only the most recent event ids")
    func seenMessageIDsAreBounded() {
        var reducer = SessionReducer()
        let first = event(sequence: 1, kind: .sessionStarted)
        expectApplied(reducer.apply(first))

        let extra = 250
        var last = first
        for sequence in 2...(SessionReducer.maximumSeenMessageIDs + extra) {
            last = event(sequence: sequence, kind: .activity)
            expectApplied(reducer.apply(last))
        }

        #expect(reducer.seenMessageIDs.count == SessionReducer.maximumSeenMessageIDs)
        #expect(reducer.seenMessageIDs.contains(last.id))
        #expect(!reducer.seenMessageIDs.contains(first.id))
        #expect(reducer.sessions["s1"]?.lastSequence == SessionReducer.maximumSeenMessageIDs + extra)
    }

    @Test("A repeated event is still ignored, whether its id is remembered or long forgotten")
    func duplicatesAreNotReadmitted() {
        var reducer = SessionReducer()
        let first = event(sequence: 1, kind: .sessionStarted)
        expectApplied(reducer.apply(first))
        var last = first
        for sequence in 2...(SessionReducer.maximumSeenMessageIDs + 10) {
            last = event(sequence: sequence, kind: .activity)
            expectApplied(reducer.apply(last))
        }
        let before = reducer.sessions["s1"]

        // A retry arrives right behind its original: still a duplicate.
        #expect(reducer.apply(last) == .ignoredDuplicate)
        // An id old enough to be forgotten carries an old sequence, which
        // the session has moved past: ignored as stale, never applied.
        #expect(reducer.apply(first) == .ignoredStale)
        #expect(reducer.sessions["s1"] == before)
    }

    @Test("A restored id set larger than the bound is trimmed")
    func restoredIDsAreTrimmed() {
        let ids = Set((0..<(SessionReducer.maximumSeenMessageIDs + 500)).map { _ in UUID() })
        var reducer = SessionReducer(seenMessageIDs: ids)

        #expect(reducer.seenMessageIDs.count == SessionReducer.maximumSeenMessageIDs)
        #expect(reducer.seenMessageIDs.isSubset(of: ids))
        // Remembered ids still reject their events.
        let known = AgentEvent(
            id: reducer.seenMessageIDs.first ?? UUID(),
            sessionID: "s1", sequence: 1, kind: .sessionStarted, agent: .claude
        )
        #expect(reducer.apply(known) == .ignoredDuplicate)
    }

    // MARK: Scanner

    @Test("Absurd token counts saturate instead of overflowing")
    func tokenTotalsSaturate() {
        var scanner = TranscriptInsightsScanner(homeDirectory: nil)
        let huge: [String: Any] = [
            "input_tokens": Int.max,
            "cache_read_input_tokens": Int.max,
            "cache_creation_input_tokens": Int.max,
            "output_tokens": Int.max,
        ]
        for id in ["msg_1", "msg_2", "msg_3"] {
            scanner.consume(line: assistantLine(id: id, usage: huge))
        }
        // The same message again takes the path that subtracts and re-adds.
        scanner.consume(line: assistantLine(id: "msg_3", usage: huge))
        // Without an id every line is added.
        scanner.consume(line: assistantLine(id: nil, usage: huge))

        let cache = scanner.insights.cache
        let ceiling = TranscriptInsightsScanner.maximumCount
        #expect(cache.inputTokens == ceiling)
        #expect(cache.cacheReadTokens == ceiling)
        #expect(cache.cacheCreationTokens == ceiling)
        #expect(cache.outputTokens == ceiling)
        // Sums the app makes from these stay representable.
        #expect(cache.inputTokens + cache.cacheReadTokens + cache.cacheCreationTokens > 0)
        #expect((scanner.insights.contextTokens ?? 0) == 3 * ceiling)
        #expect(scanner.insights.contextFraction == 1)
    }

    @Test("Ordinary token counts are added exactly as before")
    func ordinaryTotalsAreUnchanged() {
        var scanner = TranscriptInsightsScanner(homeDirectory: nil)
        scanner.consume(line: assistantLine(id: "msg_1", usage: usage(input: 10, read: 200, creation: 30, output: 5)))
        scanner.consume(line: assistantLine(id: "msg_1", usage: usage(input: 10, read: 200, creation: 30, output: 9)))
        scanner.consume(line: assistantLine(id: "msg_2", usage: usage(input: 1, read: 2, creation: 3, output: 4)))

        let cache = scanner.insights.cache
        #expect(cache.inputTokens == 11)
        #expect(cache.cacheReadTokens == 202)
        #expect(cache.cacheCreationTokens == 33)
        #expect(cache.outputTokens == 13)
        #expect(scanner.insights.contextTokens == 6)
    }

    @Test("A running total stays inside zero and the ceiling")
    func totalHelperSaturates() {
        let ceiling = TranscriptInsightsScanner.maximumCount
        #expect(TranscriptInsightsScanner.total(5, adding: 7) == 12)
        #expect(TranscriptInsightsScanner.total(5, adding: -7) == 0)
        #expect(TranscriptInsightsScanner.total(ceiling, adding: ceiling) == ceiling)
        #expect(TranscriptInsightsScanner.total(Int.max, adding: Int.max) == ceiling)
        #expect(TranscriptInsightsScanner.total(Int.min, adding: -1) == 0)
    }

    @Test("Line, duration and compaction counts are held to the same ceiling")
    func otherCountsAreBounded() {
        var scanner = TranscriptInsightsScanner(homeDirectory: nil)
        scanner.consume(line: line([
            "type": "cost-state",
            "totalLinesAdded": Int.max,
            "totalLinesRemoved": -40,
            "totalDuration": 1_500,
        ]))
        scanner.consume(line: line([
            "type": "system",
            "subtype": "compact_boundary",
            "compactMetadata": ["trigger": "auto", "preTokens": Int.max, "postTokens": 9_000],
        ]))

        let ceiling = TranscriptInsightsScanner.maximumCount
        #expect(scanner.insights.cost?.linesAdded == ceiling)
        #expect(scanner.insights.cost?.linesRemoved == 0)
        #expect(scanner.insights.cost?.durationMs == 1_500)
        #expect(scanner.insights.compactions.last?.preTokens == ceiling)
        #expect(scanner.insights.compactions.last?.postTokens == 9_000)
    }

    // MARK: Transcript cache retention

    @Test("Nothing is dropped while the cache is within its capacity")
    func retentionKeepsEverythingWithinCapacity() {
        let cached = ["/a": date(1), "/b": date(2), "/c": date(3)]
        #expect(TranscriptCacheRetention.pathsToEvict(cached: cached, selected: ["/c"], capacity: 3).isEmpty)
        #expect(TranscriptCacheRetention.pathsToEvict(cached: [:], selected: [], capacity: 0).isEmpty)
    }

    @Test("Beyond capacity the least recently written files outside the pass are dropped")
    func retentionDropsOldestSpareFiles() {
        let cached = ["/a": date(1), "/b": date(2), "/c": date(3), "/d": date(4), "/e": date(5)]

        let evicted = TranscriptCacheRetention.pathsToEvict(cached: cached, selected: ["/e", "/a"], capacity: 3)

        // "/a" is the oldest file but is in the current pass, so it stays.
        #expect(evicted == ["/b", "/c"])
    }

    @Test("The files of the current pass always stay, even past capacity")
    func retentionNeverDropsTheCurrentPass() {
        let cached = ["/a": date(1), "/b": date(2), "/c": date(3)]

        let evicted = TranscriptCacheRetention.pathsToEvict(cached: cached, selected: ["/a", "/b"], capacity: 1)

        #expect(evicted == ["/c"])
    }

    @Test("Ties are broken by path, so a pass always drops the same files")
    func retentionIsDeterministic() {
        let cached = ["/a": date(1), "/b": date(1), "/c": date(1)]

        let evicted = TranscriptCacheRetention.pathsToEvict(cached: cached, selected: [], capacity: 1)

        #expect(evicted == ["/b", "/c"])
    }

    // MARK: Fixtures

    private func event(sequence: Int, kind: AgentEventKind) -> AgentEvent {
        AgentEvent(
            sessionID: "s1",
            sequence: sequence,
            kind: kind,
            agent: .claude,
            timestamp: Date(timeIntervalSince1970: 100 + Double(sequence))
        )
    }

    private func expectApplied(_ result: ReductionResult) {
        guard case .applied = result else {
            Issue.record("expected the event to be applied, got \(result)")
            return
        }
    }

    private func date(_ second: Double) -> Date { Date(timeIntervalSince1970: second) }

    private func usage(input: Int, read: Int, creation: Int, output: Int) -> [String: Any] {
        [
            "input_tokens": input,
            "cache_read_input_tokens": read,
            "cache_creation_input_tokens": creation,
            "output_tokens": output,
        ]
    }

    private func assistantLine(id: String?, usage: [String: Any]) -> Data {
        var message: [String: Any] = [
            "model": "claude-opus-4-5-20251101",
            "role": "assistant",
            "content": [Any](),
            "usage": usage,
        ]
        if let id { message["id"] = id }
        return line(["type": "assistant", "sessionId": "session-1", "message": message])
    }

    private func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
