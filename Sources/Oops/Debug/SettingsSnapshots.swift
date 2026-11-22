#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// Debug builds only: `-SettingsSnapshots <dir> -SettingsPreviewProviders YES` renders the
/// speech-model parts of Settings to PNGs offscreen, light and dark, and exits, like `HelloSnapshots`. A model
/// store that never fetches drives every state; nothing is downloaded or saved. Glass renders flat here.
@MainActor enum SettingsSnapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferences = Preferences()
        let store = preferences.providers
        let local = LocalModels(store: InertModelStore())
        let keyboards = KeyboardModelDriver(defaults: nil, sources: { AsyncStream { _ in } })
        let sources = [
            KeyboardInputSource(id: "com.apple.keylayout.ABC", name: "ABC", languages: ["en"]),
            KeyboardInputSource(id: "com.apple.keylayout.French", name: "French", languages: ["fr"]),
            KeyboardInputSource(id: "com.apple.keylayout.Russian", name: "Russian", languages: ["ru"]),
        ]
        let file = URL(fileURLWithPath: "/dev/null")
        local.seed("parakeet_unified_en", .installed, file: file)
        local.seed("parakeet_v3", .downloading(0.4))
        local.seed("whisper_large_v3_turbo", .installed, file: file)
        local.seed("qwen3_asr06_b", .failed(LocalModels.message(ModelDownloadError.network("timed out"))))
        local.seed("cohere_transcribe", .verifying)
        keyboards.setMapping(KeyboardModelChoice(modelID: "whisper_large_v3_turbo", language: "en"), for: sources[0].id)
        keyboards.setMapping(KeyboardModelChoice(modelID: "nemotron_3_5_asr", language: "fr"), for: sources[1].id)
        keyboards.setEnabled(true)

        let claude = store.provider("claude-code")
        let target = SpeechModelPickerTarget(id: "snapshot", language: "en", current: { .local("whisper_large_v3_turbo") }, choose: { _ in })
        let historyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("oops-history-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: historyFolder) }
        let history = sampleHistory(in: historyFolder)
        let actions = ActionLibraryModel(preview: true)
        let pages: [(String, () -> AnyView)] = [
            ("actions-wheel", { AnyView(ActionsPage(store: store, navigation: ActionsNavigation(library: actions), spare: SpareSpaceModel(), library: actions)) }),
            ("dictate-history", { AnyView(DictationHistoryPage(model: history)) }),
            ("providers", { AnyView(ProvidersPage(store: store, preferences: preferences)) }),
            ("picker-picks", { AnyView(SpeechModelPage(target: target, store: store, local: local) {}) }),
            ("provider-models", { AnyView(claude.map { ProviderDetail(provider: $0, store: store, preferences: preferences) }) }),
            ("dictate-whisper", {
                store.chooseDictateModel(.local("whisper_large_v3_turbo")); store.chooseDictateLanguage("fr")
                return AnyView(DictatePage(store: store, local: local, keyboards: keyboards, sources: sources, detail: .constant(nil)))
            }),
            ("dictate-parakeet", {
                store.chooseDictateModel(.local("parakeet_unified_en"))
                return AnyView(DictatePage(store: store, local: local, keyboards: keyboards, sources: sources, detail: .constant(nil)))
            }),
        ]
        // The first renders after launch come out without glass buttons; the second pass overwrites them.
        for _ in 0..<2 {
            for (name, page) in pages {
                for scheme in [ColorScheme.light, .dark] {
                    write(page(), scheme: scheme, to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }

    /// A history of made-up dictations of several ages, in a folder of its own.
    private static func sampleHistory(in folder: URL) -> DictationHistoryModel {
        let file = folder.appendingPathComponent("dictations.json"), now = DictationHistory.now(), minute = 60_000
        var store = DictationHistoryStore(file: file, retention: .week, now: now)
        let samples: [(minutes: Int, text: String, app: String, bundleID: String, model: String, language: String?)] = [
            (26 * 60, "Thanks for the notes, I’ll go through them tonight.", "Mail", "com.apple.mail", "Parakeet Unified", "en"),
            (3 * 60, "On se retrouve jeudi après-midi pour la démo. J’aurai fini la page d’historique d’ici là, et il restera à "
                + "vérifier la recherche, la suppression d’une entrée et le menu des dictées récentes avant de livrer la version.",
             "Notes", "com.apple.Notes", "Whisper Large v3 Turbo", "fr"),
            (2, "Let’s move the review to Thursday afternoon, the build should be ready by then.", "TextEdit", "com.apple.TextEdit",
             "Parakeet Unified", nil),
        ]
        for sample in samples {
            _ = try? store.record(DictationHistoryDraft(text: sample.text, application: sample.app, bundleID: sample.bundleID,
                                                        model: sample.model, language: sample.language), now: now - sample.minutes * minute)
        }
        return DictationHistoryModel(file: file, defaults: UserDefaults(suiteName: "oops.snapshots") ?? .standard)
    }

    private static func write(_ content: AnyView, scheme: ColorScheme, to url: URL) {
        let view = content
            .frame(width: 564)
            .padding(.horizontal, 28).padding(.vertical, 20)
            .fixedSize(horizontal: false, vertical: true)
            .background(LinearGradient(colors: scheme == .dark ? [Color(white: 0.16), Color(red: 0.12, green: 0.14, blue: 0.22)]
                                                                : [Color(white: 0.93), Color(red: 0.86, green: 0.89, blue: 0.96)],
                                       startPoint: .top, endPoint: .bottom))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return print("Couldn't render \(url.lastPathComponent)") }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A model store with nothing on disk that never fetches.
private struct InertModelStore: ModelDownloading {
    func download(_ request: ModelDownloadRequest) -> AsyncThrowingStream<ModelDownloadProgress, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ModelDownloadError.cancelled) }
    }
    func cancel(fileName: String) async {}
    func delete(fileName: String) async throws {}
    func isInstalled(_ request: ModelDownloadRequest) async -> Bool { false }
    func installedFileURL(for request: ModelDownloadRequest) async -> URL? { nil }
}
#endif
