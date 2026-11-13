import OopsCore

extension AppDelegate {
    /// The dictation session, only while dictation is switched on. Its recorder exists only with the speech
    /// engine: a build without it has no microphone usage text, and macOS ends a process that touches the
    /// microphone without one. It writes through Fix's editor, whose clipboard bookkeeping is per instance.
    func makeDictation() -> DictationSession? {
        guard DebugFlags.dictation else { return nil }
        let engine = DictationEngineProvider.engine()
        let recorder = engine.map { _ in DictationRecorder(source: DictationMicrophone()) }
        let editor = session.editor
        let drop = DictationDropOwner(owner: drop) { try? await editor.focusedGeometry() }
        let providers = preferences.providers, local = LocalModels.shared
        startSpeechModels(providers, local)
        return DictationSession(recorder: recorder, engine: engine,
                                modelPath: { providers.dictationModelPath(local, override: DebugFlags.dictationModel) },
                                language: { providers.dictationLanguageHint(local, override: DebugFlags.dictationModel) },
                                mode: { DictationMode.saved }, insert: { await editor.insert($0) }, drop: drop,
                                status: { [weak self] in self?.preferences.status = $0 })
    }

    /// Reads which models are installed, then warms the selected one.
    private func startSpeechModels(_ providers: ProviderStore, _ local: LocalModels) {
        Task { [weak self] in
            await local.refresh()
            self?.warmUpDictation()
        }
    }

    /// Warms the speech model after launch when dictation can run: it is on, the engine and the model are
    /// here, and Dictate has a shortcut.
    func warmUpDictation() {
        guard let dictation, ShortcutSettings.shared.shortcut(.dictate) != nil else { return }
        dictation.warmUp()
    }
}
