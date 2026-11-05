import XCTest
@testable import OopsCore

final class ProvidersTests: XCTestCase {
    private var chatGPT: [CatalogModel] { get throws { try ChatGPTModels.decode(Data(chatGPTModelsFixture.utf8)).map(CatalogModel.init) } }
    private let claude = [CatalogModel(id: "haiku", name: "Haiku 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
                          CatalogModel(id: "sonnet", name: "Sonnet 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
                          CatalogModel(id: "claude-haiku-4-5", name: "Haiku 4.5")]
    private func providers(chatgpt: [String] = ["gpt-6-luna"], claude: [String] = ["haiku", "sonnet"]) -> [Provider] {
        var a = Provider.chatGPT(); a.shownModels = chatgpt
        var b = Provider.claudeCode(); b.shownModels = claude
        return [a, b]
    }
    private func selection(_ provider: String, _ model: String, effort: String? = nil, fast: Bool = false) -> ModelSelection {
        let choice = ModelSelection.Choice(providerID: provider, modelID: model)
        var selection = ModelSelection(choice: choice)
        selection.set(.init(effort: effort, fast: fast), for: choice)
        return selection
    }

    func testProvidersRoundTripThroughJSON() throws {
        let list = providers() + [.api(name: "Gemini · Work", baseURL: "https://example.com/v1", preset: "gemini"),
                                  .api(name: "Local", baseURL: "http://localhost:1234/v1", preset: nil)]
        XCTAssertEqual(try JSONDecoder().decode([Provider].self, from: JSONEncoder().encode(list)), list)
        let saved = selection("claude-code", "haiku", effort: "low")
        XCTAssertEqual(try JSONDecoder().decode(ModelSelection.self, from: JSONEncoder().encode(saved)), saved)
    }

    func testEffortsDropMinimalAndUltraAndKeepCatalogDescriptions() throws {
        let sol = try XCTUnwrap(try chatGPT.first { $0.id == "gpt-6.1-sol" })
        XCTAssertEqual(sol.efforts.map(\.id), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(sol.efforts[0].description, "Synthetic: lightest effort")
        XCTAssertEqual(sol.name, "GPT-6.1 Sol")
        XCTAssertEqual(sol.fast?.name, "Fast")
        let mixed = CatalogModel(id: "m", name: "M", efforts: ["max", "minimal", "none", "ultra", "low"])
        XCTAssertEqual(mixed.efforts.map(\.id), ["none", "low", "max"])
        XCTAssertNil(CatalogModel(ClaudeCode.Model(value: "opus", name: "Opus 5.5", resolved: "claude-opus-5-5", efforts: ["low"], fast: true)).fast)
    }

    func testChoiceKeptAcrossProvidersWithEachModelsOwnEffort() throws {
        var saved = selection("claude-code", "sonnet", effort: "high")
        saved.set(.init(effort: "medium"), for: .init(providerID: "chatgpt", modelID: "gpt-6-luna"))
        let (resolved, adjustments) = ModelSelection.resolve(saved, providers: providers(), catalogs: ["chatgpt": try chatGPT, "claude-code": claude])
        XCTAssertEqual(resolved, saved)
        XCTAssertEqual(adjustments, [])
    }

    func testMissingModelFallsBackToFirstShownAndExplainsIt() throws {
        let saved = selection("claude-code", "opus", effort: "ultra")
        let catalogs = ["chatgpt": try chatGPT, "claude-code": claude]
        let (resolved, adjustments) = ModelSelection.resolve(saved, providers: providers(), catalogs: catalogs)
        XCTAssertEqual(resolved.choice, .init(providerID: "chatgpt", modelID: "gpt-6-luna"))
        XCTAssertEqual(adjustments, [.modelUnavailable(previousName: "Opus")])
        let luna = try chatGPT.first { $0.id == "gpt-6-luna" }
        XCTAssertEqual(ModelSelection.notice(for: adjustments, model: luna, effort: "low"), "Opus is no longer available. Using GPT-6 Luna.")
        // A removed provider falls back the same way.
        let removed = ModelSelection.resolve(saved, providers: [providers()[0]], catalogs: catalogs)
        XCTAssertEqual(removed.selection.choice?.providerID, "chatgpt")
    }

    func testNothingSwitchedOnClearsTheChoiceInsteadOfUsingAHiddenModel() throws {
        let saved = selection("claude-code", "haiku")
        let (resolved, adjustments) = ModelSelection.resolve(saved, providers: providers(chatgpt: [], claude: []),
                                                            catalogs: ["chatgpt": try chatGPT, "claude-code": claude])
        XCTAssertNil(resolved.choice)
        XCTAssertEqual(ModelSelection.notice(for: adjustments, model: nil, effort: nil),
                       "Haiku is no longer available. Switch on a model in Providers.")
    }

    func testUnloadedCatalogKeepsTheSavedChoice() {
        let saved = selection("claude-code", "anything", effort: "ultra", fast: true)
        XCTAssertEqual(ModelSelection.resolve(saved, providers: providers(), catalogs: [:]).selection, saved)
    }

    func testEffortAndFastFollowTheModel() throws {
        let catalogs = ["chatgpt": try chatGPT, "claude-code": claude]
        let ultra = ModelSelection.resolve(selection("chatgpt", "gpt-6-luna", effort: "ultra", fast: true), providers: providers(), catalogs: catalogs)
        XCTAssertEqual(ultra.selection.settings(for: .init(providerID: "chatgpt", modelID: "gpt-6-luna")), .init(effort: "max", fast: true))
        XCTAssertEqual(ultra.adjustments, [.effortUnavailable(previous: "ultra")])
        let noEffort = ModelSelection.resolve(selection("claude-code", "claude-haiku-4-5", effort: "low", fast: true),
                                              providers: providers(claude: ["claude-haiku-4-5"]), catalogs: catalogs)
        XCTAssertEqual(noEffort.selection.settings(for: .init(providerID: "claude-code", modelID: "claude-haiku-4-5")), .init(effort: nil, fast: false))
        XCTAssertEqual(noEffort.adjustments, [.effortUnavailable(previous: "low"), .fastUnavailable])
        XCTAssertEqual(ModelSelection.notice(for: noEffort.adjustments, model: claude[2], effort: nil),
                       "Low isn’t available for Haiku 4.5. Fast isn’t available for Haiku 4.5.")
    }

    func testNearestEffortAndReset() throws {
        let luna = try XCTUnwrap(try chatGPT.first { $0.id == "gpt-6-luna" })
        XCTAssertEqual(ModelSelection.nearestEffort("minimal", in: luna), "low")
        XCTAssertEqual(ModelSelection.nearestEffort("ultra", in: luna), "max")
        XCTAssertEqual(ModelSelection.nearestEffort("none", in: luna), "low")
        XCTAssertEqual(ModelSelection.nearestEffort("unknown", in: luna), "medium")
        XCTAssertNil(ModelSelection.nearestEffort("low", in: claude[2]))
        XCTAssertEqual(ModelSelection.reset(luna), .init(effort: "low", fast: false))
    }

    func testNamesFollowCodexFormatting() {
        XCTAssertEqual(ModelSelection.modelName("GPT-6-Luna"), "GPT-6 Luna")
        XCTAssertEqual(ModelSelection.modelName("gpt-5.1-codex-mini"), "GPT-5.1 Codex Mini")
        XCTAssertEqual(ModelSelection.modelName("Haiku 5.5"), "Haiku 5.5")
        XCTAssertEqual(ModelSelection.effortName("xhigh"), "Extra High")
    }

    func testInitialShownAndFreshInstall() {
        XCTAssertEqual(ModelSelection.initialShown(claude, preferred: ModelSelection.preferredClaude), ["haiku"])
        XCTAssertEqual(ModelSelection.initialShown(claude, preferred: ["gone"]), ["haiku"])
        XCTAssertEqual(ModelSelection.initialShown([], preferred: ["haiku"]), [])

        let (list, saved) = ModelSelection.initial()
        XCTAssertEqual(list.map(\.id), ["chatgpt"])
        XCTAssertEqual(list[0].shownModels, ["gpt-6-luna"])
        XCTAssertEqual(saved.choice, .init(providerID: "chatgpt", modelID: "gpt-6-luna"))
        XCTAssertEqual(saved.settings(for: saved.choice!), .init(effort: "low", fast: false))
    }
}
