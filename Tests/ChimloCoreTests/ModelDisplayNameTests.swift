import Testing
@testable import ChimloCore

@Suite("Model display names")
struct ModelDisplayNameTests {
    @Test("Claude model versions are derived without a release table", arguments: [
        ("claude-sonnet-5-20260701", "Sonnet 5"),
        ("us.anthropic.claude-fable-5-20260701-v1:0", "Fable 5"),
        ("claude-opus-4-8-20250514", "Opus 4.8"),
        ("claude-haiku-4-5@20251001", "Haiku 4.5"),
        ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
    ])
    func claudeNames(modelID: String, expected: String) {
        #expect(ModelDisplayName.resolve(modelID: modelID, agent: .claude) == expected)
    }

    @Test("Unknown provider model identifiers remain unchanged")
    func unknownModelName() {
        #expect(ModelDisplayName.resolve(
            modelID: "company/custom-model-v2",
            agent: .other
        ) == "company/custom-model-v2")
    }
}
