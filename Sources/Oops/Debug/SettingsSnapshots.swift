#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// Debug builds only: `-SettingsSnapshots <dir> -DebugDictation YES -SettingsPreviewProviders YES` renders the
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

        let claude = store.provider("claude-code")
        let pages: [(String, () -> AnyView)] = [
            ("providers", { AnyView(ProvidersPage(store: store, preferences: preferences, local: local)) }),
            ("providers-all", { AnyView(LocalModelsCard(store: store, local: local, showingAll: true)) }),
            ("provider-models", { AnyView(claude.map { ProviderDetail(provider: $0, store: store, preferences: preferences) }) }),
            ("dictate-whisper", {
                store.chooseDictateModel(.local("whisper_large_v3_turbo")); store.chooseDictateLanguage("fr")
                return AnyView(DictatePage(store: store, local: local, keyboards: keyboards, sources: sources))
            }),
            ("dictate-parakeet", {
                store.chooseDictateModel(.local("parakeet_unified_en"))
                return AnyView(DictatePage(store: store, local: local, keyboards: keyboards, sources: sources))
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
