import XCTest
@testable import OopsCore

/// The catalog's models as Dictate and the capability resolver read them.
final class SpeechModelDictateTests: XCTestCase {
    func testSwitchingBetweenCatalogModelsKeepsOrDropsTheLanguage() {
        var selection = DictateSelection(model: .local("whisper_large_v3_turbo"), language: "fr")
        selection.switchModel(to: .local("parakeet_v3"), languages: SpeechModelCatalog.parakeetV3)
        XCTAssertEqual(selection.language, "fr")
        selection.switchModel(to: .local("parakeet_unified_en"), languages: SpeechModelCatalog.parakeetUnifiedEnglish)
        XCTAssertNil(selection.language)
        XCTAssertTrue(SpeechModelCatalog.parakeetUnifiedEnglish.isSingleLanguage)
    }

    func testAutomaticIsDetectionOnlyWhereTheModelDetects() {
        XCTAssertEqual(SpeechModelCatalog.whisperLargeV3Turbo.automaticLanguage, SpeechLanguage.auto)
        XCTAssertEqual(SpeechModelCatalog.parakeetUnifiedEnglish.automaticLanguage, "en")
    }

    func testTheCatalogStepKnowsOnlyOopsManagedModels() throws {
        let lookup = SpeechModelCatalog.capabilityLookup
        let parakeet = try XCTUnwrap(lookup(nil, "parakeet_unified_en"))
        XCTAssertEqual(parakeet, ModelCapabilities(text: false, voice: true, streaming: true, languages: ["en"], source: .catalog))
        XCTAssertEqual(lookup(nil, "parakeet_v3")?.streaming, false)
        XCTAssertNil(lookup(nil, "gpt-6-luna"))
        XCTAssertNil(lookup(.api(preset: nil), "parakeet_unified_en"))
        let resolver = CapabilityResolver(catalog: lookup)
        XCTAssertEqual(resolver.resolve(modelID: "whisper_large_v3_turbo", kind: nil, canProbe: false).capabilities?.voice, true)
    }
}
