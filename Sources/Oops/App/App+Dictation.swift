import Foundation
import OopsCore

extension AppDelegate {
    /// The dictation session, only while dictation is switched on. Its recorder exists only with the speech
    /// engine: a build without it has no microphone usage text, and macOS ends a process that touches the
    /// microphone without one. It writes through Fix's editor, whose clipboard bookkeeping is per instance.
    func makeDictation() -> DictationSession? {
        guard DebugFlags.dictation else { return nil }
        let engine = DictationEngineProvider.engine()
        let forced: DictationMicrophoneAccess? = switch DebugFlags.microphoneAccess {
        case "denied": .denied
        case "undetermined": .undetermined
        default: nil
        }
        let recorder = engine.map { _ in
            // A WAV in place of the microphone, so a dictation can be checked with nobody speaking.
            let source: any DictationAudioSource = DebugFlags.dictationAudioFile.map {
                DictationAudioFile(url: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath), pace: .realTime)
            } ?? DictationMicrophone(access: { forced ?? .current })
            return DictationRecorder(source: source)
        }
        let editor = session.editor
        let loudness = DictationLoudnessFeed()
        let drop = DictationDropOwner(owner: drop, loudness: loudness) { try? await editor.focusedGeometry() }
        let providers = preferences.providers, local = LocalModels.shared
        startSpeechModels(providers, local)
        let vocabulary = VocabularyStore.shared
        let cleanup = DictationSession.Cleanup(
            vocabulary: { providers.dictationVocabulary(local, override: DebugFlags.dictationModel, entries: vocabulary.entries) },
            small: { SmallCleanups.saved }, language: { providers.dictationCleanupLanguage(local, override: DebugFlags.dictationModel) },
            mode: { DictationCleanupMode.saved },
            backend: { try providers.cleanupBackend() }, replace: { await Self.replace($0, with: $1, in: editor) })
        return DictationSession(recorder: recorder, engine: engine, hostedEngine: { nil },
                                modelPath: { providers.dictationModelPath(local, override: DebugFlags.dictationModel) },
                                language: { providers.dictationLanguageHint(local, override: DebugFlags.dictationModel) },
                                mode: { DictationMode.saved }, insert: { await editor.insert($0) }, drop: drop, loudness: loudness,
                                status: { [weak self] in self?.preferences.status = $0 }, cleanup: cleanup,
                                escape: { [weak self] in self?.shortcuts.armCancel($0) },
                                shortcutModifiers: { ShortcutSettings.shared.shortcut($0 ? .dictateAndCleanUp : .dictate)?.modifiers })
    }

    /// Swaps text a dictation wrote for its cleanup, as Fix swaps a correction in: the modifiers up, the clipboard
    /// saved, and keys and clicks held back while the swap runs.
    private static func replace(_ inserted: String, with cleaned: String, in editor: EditorAccess) async -> InsertReplacement {
        do {
            try await KeyboardGate.waitForModifierRelease()
            let clipboard = try await editor.prepareClipboard()
            defer { clipboard.restoreIfOwned() }
            let gate = try KeyboardGate()
            defer { gate.release() }
            return try await editor.replaceInserted(inserted, with: cleaned, clipboard: clipboard, protected: { gate.isActive })
        } catch {
            DictationSession.log.notice("cleanup replace failed error=\(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
    }

    /// Reads which models are installed, then warms the selected one, and lets the keyboard's language switch
    /// Dictate's model once a mapping exists.
    private func startSpeechModels(_ providers: ProviderStore, _ local: LocalModels) {
        Task { [weak self] in
            await local.refresh()
            self?.warmUpDictation()
        }
        let keyboards = KeyboardModelDriver.shared
        keyboards.isInstalled = { local.isInstalled($0) }
        keyboards.apply = { [weak self] choice in
            providers.applyKeyboardChoice(choice)
            self?.warmUpDictation()
        }
        keyboards.start()
    }

    /// Warms the speech model after launch when dictation can run: it is on, the engine and the model are
    /// here, and Dictate has a shortcut.
    func warmUpDictation() {
        guard let dictation, ShortcutSettings.shared.shortcut(.dictate) != nil else { return }
        dictation.warmUp()
    }
}
