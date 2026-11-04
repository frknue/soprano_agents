import AppKit
import Testing
@testable import SopranoAgentsCore

struct ProviderPromptTests {
    @Test func theFirstJSONObjectIsFoundInsideFencesAndProse() throws {
        #expect(try ProviderPrompt.firstJSONObject(in: "```json\n{\"title\": \"Fix {it}\"}\n```") == ["title": "Fix {it}"])
        #expect(try ProviderPrompt.firstJSONObject(in: "Sure: {\"a\": {\"b\": 1}} done") == ["a": ["b": 1]])
        #expect(throws: ProviderError.self) { try ProviderPrompt.firstJSONObject(in: "no json") }
    }
}
