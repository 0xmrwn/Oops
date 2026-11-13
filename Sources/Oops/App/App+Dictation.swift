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
        let recorder = engine.map { _ in DictationRecorder(source: DictationMicrophone(access: { forced ?? .current })) }
        let editor = session.editor
        let loudness = DictationLoudnessFeed()
        let drop = DictationDropOwner(owner: drop, loudness: loudness) { try? await editor.focusedGeometry() }
        return DictationSession(recorder: recorder, engine: engine, modelPath: { DebugFlags.dictationModel }, mode: { DictationMode.saved },
                                insert: { await editor.insert($0) }, drop: drop, loudness: loudness,
                                status: { [weak self] in self?.preferences.status = $0 })
    }

    /// Warms the speech model after launch when dictation can run: it is on, the engine and the model are
    /// here, and Dictate has a shortcut.
    func warmUpDictation() {
        guard let dictation, ShortcutSettings.shared.shortcut(.dictate) != nil else { return }
        dictation.warmUp()
    }
}
