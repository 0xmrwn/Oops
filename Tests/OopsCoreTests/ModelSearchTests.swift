@testable import OopsCore
import Testing

struct ModelSearchTests {
    private let groups: [(provider: String, models: [CatalogModel])] = [
        ("ChatGPT", [CatalogModel(id: "luna", name: "GPT-6 Luna"), CatalogModel(id: "sol", name: "GPT-6.2 Sol")]),
        ("OpenAI API", [CatalogModel(id: "pro", name: "GPT-6.2 Pro")]),
        ("Gemini", [CatalogModel(id: "g3", name: "Gemini 3 Pro")]),
    ]

    private func names(_ query: String) -> [String] {
        ModelSearch.filter(groups, query: query) { $0 }.map { "\($0.provider): " + $0.models.map(\.name).joined(separator: ", ") }
    }

    @Test func `every word must match the name or the provider`() {
        #expect(names("pro") == ["OpenAI API: GPT-6.2 Pro", "Gemini: Gemini 3 Pro"])
        #expect(names("gpt pro") == ["OpenAI API: GPT-6.2 Pro"])
        #expect(names("openai") == ["OpenAI API: GPT-6.2 Pro"])
        #expect(names("PRO") == names("pro"))
        #expect(names("") == names("  "))
        #expect(names("").count == 3)
        #expect(ModelSearch.filter(groups, query: "  ") { $0 }.map(\.models.count) == [2, 1, 1])
    }

    @Test func `the highlight returns to the first row once results come back`() {
        #expect(ModelSearch.highlight(nil, in: ["a", "b"]) == "a")
        #expect(ModelSearch.highlight("b", in: ["a", "b"]) == "b")
        #expect(ModelSearch.highlight("c", in: ["a", "b"]) == "a")
        #expect(ModelSearch.highlight("a", in: [String]()) == nil)
    }

    @Test func `a row above the groups matches the same way`() {
        #expect(ModelSearch.matches("same", "Same as Fix"))
        #expect(!ModelSearch.matches("haiku", "Same as Fix"))
    }
}
