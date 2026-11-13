import Foundation
@testable import Oops
import OopsCore
import Testing

/// Dictate's model and language, from the selection to the file and hint the engine gets.
@MainActor struct DictateModelTests {
    private let whisper = SpeechModelCatalog.model(id: "whisper_large_v3_turbo")!, parakeet = SpeechModelCatalog.model(id: "parakeet_unified_en")!

    private func make(installed: [SpeechModel]) async -> (ProviderStore, LocalModels, FakeModelStore) {
        let files = FakeModelStore(installed: Set(installed.map(\.artifact.fileName)))
        let local = LocalModels(store: files)
        await local.refresh()
        let store = ProviderStore(chatGPT: ChatGPTAuth(store: NoChatGPTCredentials(), openBrowser: { _ in }), preview: true)
        return (store, local, files)
    }

    @Test func `the menu lists installed models, and says which can't stream`() async {
        let (store, local, _) = await make(installed: [parakeet, whisper])
        let options = store.dictateOptions(local)
        #expect(options.map(\.reference) == [.local(parakeet.id), .local(whisper.id)])
        #expect(options.map(\.streams) == [true, false])
        #expect(options[0].isSingleLanguage)
        #expect(options[1].languages.first == SpeechLanguage.auto)
        #expect(store.dictateOption(local) == nil)
    }

    @Test func `a selected installed model gives its file and the language as a hint`() async {
        let (store, local, _) = await make(installed: [whisper])
        #expect(store.dictationModelPath(local, override: nil) == nil)
        store.chooseDictateModel(.local(whisper.id))
        #expect(store.dictationModelPath(local, override: nil) == FakeModelStore.url(whisper.artifact.fileName).path)
        #expect(store.dictationLanguageHint(local, override: nil) == nil)
        store.chooseDictateLanguage("fr")
        #expect(store.dictationLanguageHint(local, override: nil) == "fr")
        #expect(store.dictateLanguage(for: DictateModelOption(whisper)) == "fr")
        store.chooseDictateLanguage(SpeechLanguage.auto)
        #expect(store.dictateSelection.language == nil)
    }

    @Test func `a one-language model shows and hints its own language`() async {
        let (store, local, _) = await make(installed: [parakeet])
        store.chooseDictateModel(.local(parakeet.id))
        #expect(store.dictateOption(local).map { store.dictateLanguage(for: $0) } == "en")
        #expect(store.dictationLanguageHint(local, override: nil) == "en")
    }

    @Test func `deleting the selected model clears the selection and leaves nothing to load`() async {
        let (store, local, _) = await make(installed: [whisper, parakeet])
        store.chooseDictateModel(.local(whisper.id)); store.chooseDictateLanguage("fr")
        await store.deleteLocalModel(parakeet, from: local)
        #expect(store.dictateSelection == DictateSelection(model: .local(whisper.id), language: "fr"))
        await store.deleteLocalModel(whisper, from: local)
        #expect(store.dictateSelection == DictateSelection())
        #expect(store.dictationModelPath(local, override: nil) == nil)
        #expect(store.dictateOptions(local).isEmpty)
    }

    @Test func `a file gone from disk leaves nothing to load`() async {
        let (store, local, files) = await make(installed: [whisper])
        store.chooseDictateModel(.local(whisper.id))
        try? await files.delete(fileName: whisper.artifact.fileName)
        await local.refresh()
        #expect(store.dictationModelPath(local, override: nil) == nil)
        #expect(store.dictateOption(local) == nil)
    }

    @Test func `the debug model wins when set`() async {
        let (store, local, _) = await make(installed: [whisper])
        store.chooseDictateModel(.local(whisper.id)); store.chooseDictateLanguage("fr")
        #expect(store.dictationModelPath(local, override: "~/lab/model.gguf") == "~/lab/model.gguf")
        #expect(store.dictationLanguageHint(local, override: "~/lab/model.gguf") == nil)
        #expect(store.dictationModelPath(local, override: "") == FakeModelStore.url(whisper.artifact.fileName).path)
    }

    @Test func `a keyboard mapping applies its model and language as they are`() async {
        let (store, _, _) = await make(installed: [whisper])
        store.chooseDictateModel(.local(parakeet.id))
        store.applyKeyboardChoice(KeyboardModelChoice(modelID: whisper.id, language: "ru"))
        #expect(store.dictateSelection == DictateSelection(model: .local(whisper.id), language: "ru"))
        store.applyKeyboardChoice(KeyboardModelChoice(modelID: whisper.id, language: SpeechLanguage.auto))
        #expect(store.dictateSelection.language == nil)
    }
}

final class NoChatGPTCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
