import Foundation
import Testing
import ChimloCore
@testable import ChimloProtocol

/// However large the hook payload Claude Code hands the helper, the request
/// the helper puts on the wire stays bounded: previews are clipped and every
/// other field is capped, so it fits one frame. A request that still cannot
/// fit is never sent, and the hook falls back to Claude Code's own prompt.
@Suite("Audit 107: blocking hook requests fit one frame")
struct Audit107TransportHookFrameTests {
    private static let token = String(repeating: "a", count: 64)

    @Test("A permission request from a payload at the hook's size limit fits one frame")
    func largestPermissionPayloadFitsOneFrame() throws {
        // Quotes and newlines double in size once JSON-escaped: the least
        // favourable ordinary file content.
        let line = "let text = \"quoted \\\"value\\\"\"\n"
        let path = "/Users/me/Projects/" + String(repeating: "deeply-nested/", count: 200) + "file.swift"
        // Fill the payload to just under the limit, whatever the limit is.
        let limit = ClaudePermissionHook.maximumPayloadBytes
        let empty = try Self.permissionPayload(path: path, content: "")
        let escapedLineBytes = try JSONSerialization.data(withJSONObject: [line]).count - 4
        let lines = (limit - empty.count - 1_024) / escapedLineBytes
        let payload = try Self.permissionPayload(path: path, content: String(repeating: line, count: lines))
        #expect(payload.count <= limit)
        #expect(payload.count > limit - 4_096)

        let hook = try ClaudePermissionHook(data: payload)
        let frame = try ChimloFrameCodec.encode(ChimloEnvelope(
            authenticationToken: Self.token,
            message: .permissionRequest(hook.request)
        ))

        #expect((hook.request.preview ?? "").utf8.count <= 4_096 + 32)
        #expect(hook.request.preview?.hasSuffix("… preview clipped") == true)
        #expect(frame.count <= ChimloFrameCodec.maximumPayloadBytes + ChimloFrameCodec.headerBytes)
        // The preview is a fraction of the payload it was cut from.
        #expect(frame.count < payload.count / 2)
    }

    @Test("A question request with every field at its bound fits one frame")
    func largestQuestionFitsOneFrame() throws {
        let questions: [[String: Any]] = (0..<4).map { index in
            [
                "question": "Q\(index) " + String(repeating: "why \"so\"\n", count: 200),
                "header": String(repeating: "h", count: 120),
                "multiSelect": true,
                "options": (0..<4).map { option in
                    [
                        "label": "Option \(option) " + String(repeating: "l", count: 200),
                        "description": String(repeating: "d \"q\"\n", count: 140),
                    ]
                },
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-1",
            "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion",
            "cwd": "/Users/me/Projects/overhead",
            "tool_input": ["questions": questions],
        ])
        #expect(payload.count <= ClaudeQuestionHook.maximumPayloadBytes)

        let hook = try ClaudeQuestionHook(data: payload)
        let frame = try ChimloFrameCodec.encode(ChimloEnvelope(
            authenticationToken: Self.token,
            message: .questionRequest(hook.request)
        ))

        #expect(hook.request.questions.count == 4)
        #expect(frame.count <= ChimloFrameCodec.maximumPayloadBytes + ChimloFrameCodec.headerBytes)
    }

    @Test("A request that cannot fit a frame is never sent and grants nothing")
    func oversizedRequestIsUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overhead-audit107-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeDescriptorStore(descriptorURL: directory.appendingPathComponent("runtime.json"))
        let received = RequestCounter()
        let server = try ChimloServer(
            descriptorStore: store,
            eventHandler: { _ in },
            permissionHandler: { request in
                await received.increment()
                return ProviderPermissionResponse(requestID: request.id, outcome: .allowedOnce)
            }
        )
        defer { server.stop() }
        _ = try await server.start()
        let client = try ChimloClient(descriptorStore: store, timeout: .seconds(2))
        let request = ProviderPermissionRequest(
            sessionID: "claude-1", agent: .claude, title: "overhead",
            toolName: "Write", prompt: "Write big.txt?",
            preview: String(repeating: "x", count: ChimloFrameCodec.maximumPayloadBytes * 2),
            allowsSessionApproval: true
        )

        let response = await client.requestPermission(request)

        #expect(response.outcome == .unavailable)
        #expect(!response.outcome.grantsPermission)
        #expect(await received.value == 0)
    }

    private static func permissionPayload(path: String, content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "session_id": "claude-1",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Write",
            "cwd": "/Users/me/Projects/overhead",
            "permission_mode": "default",
            "tool_input": ["file_path": path, "content": content],
        ])
    }
}

private actor RequestCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}
