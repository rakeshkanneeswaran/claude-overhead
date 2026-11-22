import Foundation
import Testing
@testable import ChimloCore

@Suite("Claude agents listing")
struct ClaudeAgentsListingTests {
    @Test("Interactive and background sessions decode with their pid and start time")
    func decodesEntries() throws {
        let json = #"""
        [
          {"pid": 4242, "cwd": "/tmp/app", "kind": "interactive", "startedAt": 1785000000000, "sessionId": "s-1", "name": "Fix the build", "status": "busy"},
          {"pid": 4343, "cwd": "/tmp/api", "kind": "background", "startedAt": 1785000060000, "sessionId": "s-2", "name": "Nightly tidy", "status": "idle"}
        ]
        """#
        let sessions = ClaudeAgentsListing.parse(Data(json.utf8))
        #expect(sessions.count == 2)
        let first = try #require(sessions.first)
        #expect(first.pid == 4242)
        #expect(first.kind == .interactive)
        #expect(first.isBusy)
        #expect(first.startedAt == Date(timeIntervalSince1970: 1_785_000_000))
        #expect(sessions.last?.kind == .background)
        #expect(sessions.last?.isBusy == false)
    }

    @Test("A newer Claude Code's unknown fields and kinds never drop the list")
    func toleratesChanges() {
        let json = #"[{"sessionId": "s-3", "kind": "cloud-mirror", "extra": {"a": 1}}, {"pid": 1}, "not an object"]"#
        let sessions = ClaudeAgentsListing.parse(Data(json.utf8))
        #expect(sessions.map(\.sessionID) == ["s-3"])
        #expect(sessions.first?.kind == .unknown)
        #expect(ClaudeAgentsListing.parse(Data("not json".utf8)).isEmpty)
    }
}
