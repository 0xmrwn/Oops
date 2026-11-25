import AppKit
import OopsCore

extension AppDelegate {
    /// The dictation session. It writes through Fix's editor, whose clipboard bookkeeping is per instance.
    func makeDictation() -> DictationSession {
        let engine = DictationEngineProvider.engine()
        let forced: DictationMicrophoneAccess? = switch DebugFlags.microphoneAccess {
        case "denied": .denied
        case "undetermined": .undetermined
        default: nil
        }
        // A WAV in place of the microphone, so a dictation can be checked with nobody speaking.
        let source: any DictationAudioSource = DebugFlags.dictationAudioFile.map {
            DictationAudioFile(url: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath), pace: .realTime)
        } ?? DictationMicrophone(access: { forced ?? .current })
        let recorder = DictationRecorder(source: source, preRoll: { DictationAudioSettings.pressPreRoll() })
        let editor = session.editor
        let loudness = DictationLoudnessFeed()
        let drop = DictationDropOwner(owner: drop, loudness: loudness) { try? await editor.focusedCaret() }
        let providers = preferences.providers, local = LocalModels.shared
        startSpeechModels(providers, local)
        let vocabulary = VocabularyStore.shared
        let cleanup = DictationSession.Cleanup(
            vocabulary: { providers.dictationVocabulary(local, override: DebugFlags.dictationModel, entries: vocabulary.entries) },
            small: { SmallCleanups.saved }, language: { providers.dictationCleanupLanguage(local, override: DebugFlags.dictationModel) },
            mode: { DictationCleanupMode.saved },
            available: { providers.hasCleanupModel }, backend: { try providers.cleanupBackend() }, replace: { await Self.replace($0, with: $1, in: editor) },
            intact: { await editor.insertedIntact($0) }, shortcutLabel: { ShortcutSettings.shared.shortcut(.dictateAndCleanUp)?.label })
        // A model file from the debug override is what a check means to run: its audio never goes to a hosted engine.
        let hosted: @MainActor () -> (any SpeechEngine)? = {
            DebugFlags.dictationModel?.isEmpty == false ? nil : providers.dictationHostedEngine(local)
        }
        let history = dictationHistory(providers, local)
        return DictationSession(recorder: recorder, engine: engine, hostedEngine: hosted,
                                modelPath: { providers.dictationModelPath(local, override: DebugFlags.dictationModel) },
                                language: { providers.dictationLanguageHint(local, override: DebugFlags.dictationModel) },
                                mode: { DictationMode.saved }, insert: { await editor.insert($0) }, drop: drop, loudness: loudness,
                                status: { [weak self] in self?.preferences.status = $0 }, cleanup: cleanup,
                                escape: { [weak self] in self?.armEscape(.dictate, $0) },
                                shortcutModifiers: { ShortcutSettings.shared.shortcut($0 ? .dictateAndCleanUp : .dictate)?.modifiers },
                                environment: DictationRecordingEnvironment(), history: history)
    }

    /// The session's history, kept by `DictationHistoryModel`, whose first touch here opens the store and so expires
    /// old entries at launch. An entry records the app in front, and the model the dictation ran with.
    private func dictationHistory(_ providers: ProviderStore, _ local: LocalModels) -> DictationSession.History {
        let model = DictationHistoryModel.shared
        model.insert = { [weak self] text in
            Task {
                await Self.stepBack()
                self?.dictation?.paste(text)
            }
        }
        return DictationSession.History(
            model: {
                let override = DebugFlags.dictationModel.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
                return override ?? providers.dictateOption(local)?.name
            },
            record: { text, language, speechModel in
                let app = NSWorkspace.shared.frontmostApplication, bundleID = app?.bundleIdentifier
                // Words written here: the app gets its switch in Turn off in apps, as one Fix corrected in does.
                if let bundleID { AppScope.shared.noteUsed(bundleID) }
                model.record(text: text, language: language, model: speechModel,
                             application: app?.localizedName ?? bundleID.map(AppScope.name), bundleID: bundleID)
            },
            replaceLast: { model.replaceLast($0) },
            last: { model.lastText(inMemory: $0) })
    }

    /// Settings' Insert: the caret is in the app Settings covered, so Oops hides and waits, at most about a second,
    /// for that app to come back to the front.
    private static func stepBack() async {
        NSApp.hide(nil)
        let me = ProcessInfo.processInfo.processIdentifier
        var polls = 0
        while polls < 20, NSWorkspace.shared.frontmostApplication?.processIdentifier == me {
            polls += 1
            try? await Task.sleep(for: .milliseconds(50))
        }
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

    /// Warms the speech model after launch when dictation can run: the model is here and Dictate has a shortcut.
    func warmUpDictation() {
        guard let dictation, ShortcutSettings.shared.shortcut(.dictate) != nil else { return }
        dictation.warmUp()
    }
}
