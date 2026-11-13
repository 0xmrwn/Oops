import Foundation
import OopsCore
import OSLog

/// Dictation from the shortcut to the caret: the shortcut's presses and releases go through the activation
/// for the current mode, whose effects start a recording, stop it for transcription or discard it. A stopped
/// recording is transcribed and written at the caret while the next press is already being heard.
///
/// Events are handled strictly in order, one at a time, by one task reading a queue: a release that comes
/// while a start is still opening the microphone waits for that start to finish. The transcription runs
/// beside the queue, so presses meanwhile reach the activation, and its end comes back through the queue.
///
/// While a recording runs, Escape cancels it (`DictationEscape`); a recording whose microphone goes away is
/// transcribed as far as it got. The last transcript is kept for Paste last dictation and the drop's Copy.
@MainActor final class DictationSession {
    enum Event {
        /// A key went down or up; `cleanUp` for the "Dictate and clean up" shortcut.
        case key(HotkeyPhase, CaptureInstant, ContinuousClock.Instant, cleanUp: Bool)
        /// The activation's deadline passed.
        case timer(ContinuousClock.Instant)
        /// A transcription is written or abandoned.
        case processed(Ending)
        /// Escape, while a recording runs.
        case cancel
        /// The recording's microphone went away.
        case inputLost
        /// Paste last dictation, from the menu or its shortcut.
        case pasteLast
        /// Dictate lost its shortcut.
        case off
    }

    /// What a stopped recording came to.
    enum Ending: Equatable {
        /// Written, or nothing worth writing (no speech, an empty transcript): the drop just leaves.
        case done
        /// Written as `text`, with Clean up on Button: the drop offers to clean it up.
        case offer(String)
        case failed(DictationFailure)
        /// No text field had focus: the transcript is kept, and the drop offers to copy it.
        case kept
    }

    /// What each dictation came to, in numbers only: never what was said.
    static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Dictation")

    private(set) var activation = DictationActivation()
    /// Held from a start until its outcome shows or the drop leaves.
    var holdsDrop = false
    /// Counts the drop's turns (a recording, a cleanup), so work that ends late knows a newer one has the drop.
    var turn = 0
    let recorder: DictationRecorder?
    /// The loudness of the recording, for the drop's visualizer; 0 when nothing records.
    let loudness: DictationLoudnessFeed
    let engine: any SpeechEngine?
    private let modelPath: @MainActor () -> String?
    private let languageHint: @MainActor () -> String?
    private let mode: @MainActor () -> DictationMode
    let insert: @MainActor (String) async -> InsertOutcome
    let drop: any DictationDrop
    /// What happens to the transcript before and after it's written (`DictationSession+Cleanup`).
    let cleanup: Cleanup
    /// The current recording's cleanup steps, read at its start.
    var plan = CleanupPlan()
    private let status: @MainActor (String) -> Void
    private let askMicrophone: @MainActor () async -> Bool
    /// The system's microphone prompt is up, or its answer is on its way to the drop.
    private var asking = false
    private let events: AsyncStream<Event>.Continuation
    private var consumer: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var armedFor: ContinuousClock.Instant?
    /// The last key-down, where a recording starts, even one the activation remembered until a transcription
    /// finished: the open microphone keeps the audio since.
    private var lastPress: CaptureInstant?
    /// The last key-up, which a release deferred by the activation's grace still ends the recording at.
    private var lastRelease: CaptureInstant?
    /// The last key-down came from "Dictate and clean up".
    private var lastPressCleans = false
    /// The model this session loaded, or is loading or warming up, and that work.
    var loadedModel: URL?
    var loading: Task<Void, any Error>?
    /// The language hint read at the last start, for its transcription.
    var language: String?
    /// The most recent transcript, written or not, held in memory only: Paste last dictation writes it again,
    /// and the kept drop copies it.
    var lastTranscript: String?
    private let escape: @MainActor ([UInt32]) -> Void
    private let shortcutModifiers: @MainActor (_ cleanUp: Bool) -> UInt32?
    let copy: @MainActor (String) -> Void
    /// The Escape chords registered now, as `escape` was last told.
    private(set) var escapeChords: [UInt32] = []
    /// Another model was chosen while a dictation held the drop: it warms once that dictation is over.
    private var warmUpDeferred = false

    /// `recorder` is nil, like `engine`, in a build without the speech engine, which may not touch the
    /// microphone. `modelPath`, `language` and `mode` are read at each start and press; `status` hears a refused
    /// start; `askMicrophone` shows the system's prompt and answers whether access was given. `escape` registers
    /// the Escape chords given (none: unregisters them), `shortcutModifiers` are the held shortcut's (Dictate's, or
    /// "Dictate and clean up"'s when `cleanUp`), and
    /// `copy` puts a transcript on the clipboard.
    init(recorder: DictationRecorder?, engine: any SpeechEngine?, modelPath: @escaping @MainActor () -> String?,
         language: @escaping @MainActor () -> String? = { nil },
         mode: @escaping @MainActor () -> DictationMode, insert: @escaping @MainActor (String) async -> InsertOutcome,
         drop: any DictationDrop, loudness: DictationLoudnessFeed = DictationLoudnessFeed(),
         status: @escaping @MainActor (String) -> Void, cleanup: Cleanup = .none,
         askMicrophone: @escaping @MainActor () async -> Bool = { await DictationMicrophoneAccess.requestAccess() },
         escape: @escaping @MainActor ([UInt32]) -> Void = { _ in }, shortcutModifiers: @escaping @MainActor (_ cleanUp: Bool) -> UInt32? = { _ in nil },
         copy: @escaping @MainActor (String) -> Void = { DictationSession.copyToClipboard($0) }) {
        self.recorder = recorder; self.engine = engine; self.modelPath = modelPath; self.languageHint = language; self.mode = mode
        self.insert = insert; self.drop = drop; self.loudness = loudness; self.status = status; self.cleanup = cleanup
        self.askMicrophone = askMicrophone; self.escape = escape; self.shortcutModifiers = shortcutModifiers; self.copy = copy
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        events = continuation
        consumer = Task { [weak self] in
            await recorder?.onInputLost { continuation.yield(.inputLost) }
            for await event in stream { await self?.handle(event) }
        }
    }

    /// The Dictate shortcut, or "Dictate and clean up" (`cleanUp`), went down or up, at the instants the hotkey
    /// event was taken.
    func shortcut(_ phase: HotkeyPhase, at capture: CaptureInstant, now: ContinuousClock.Instant, cleanUp: Bool = false) {
        events.yield(.key(phase, capture, now, cleanUp: cleanUp))
    }

    /// Escape: cancels the recording under way, if any.
    func cancel() { events.yield(.cancel) }

    /// Writes the last transcript again at the caret, once no dictation is under way.
    func pasteLast() { events.yield(.pasteLast) }
    /// Dictate lost its shortcut: a recording under way, which no key could end now, is discarded, and a press
    /// remembered for later is forgotten. A transcription already running still writes.
    func turnedOff() {
        events.yield(.off)
    }

    /// Loads the model and runs it once at low priority, away from the main actor, so the first dictation
    /// doesn't wait for it, again when another model is chosen. A failure is ignored: the first dictation loads it again.
    func warmUp() {
        // A recording is transcribed by the model and language read at its start: the engine's model can't change under it.
        guard !holdsDrop else { warmUpDeferred = true; return }
        guard let engine, let model = Self.modelURL(modelPath()), loadedModel != model else { return }
        loadedModel = model
        loading = Task.detached(priority: .background) { try await engine.warmUp(model: model) }
    }

    /// The model file at `path`, with a leading `~` expanded; nil when there is no file there.
    static func modelURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &directory), !directory.boolValue else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    private func handle(_ event: Event) async {
        // A slow start can hold a release and the next press in the queue past the release's deadline, whose
        // timer comes after them: what was due before the key went down or up is settled first, at the release.
        if case let .key(_, _, now, _) = event, let deadline = activation.deadline, deadline <= now {
            await perform(activation.timerFired(at: deadline), stoppingAt: lastRelease)
        }
        switch event {
        case let .key(.pressed, capture, now, cleanUp):
            activation.mode = mode()
            lastPress = capture; lastPressCleans = cleanUp
            await perform(activation.pressed(at: now), stoppingAt: capture)
        case let .key(.released, capture, now, _):
            lastRelease = capture
            await perform(activation.released(at: now), stoppingAt: capture)
        case let .timer(deadline):
            // A timer for an earlier deadline finds nothing due; the current one stays armed.
            if deadline == armedFor { armedFor = nil }
            await perform(activation.timerFired(at: deadline), stoppingAt: lastRelease)
        case let .processed(ending):
            let next = activation.processingFinished()
            // A press made meanwhile takes the drop straight over; otherwise the outcome shows.
            if next != .start { conclude(ending) }
            await perform(next, stoppingAt: nil)
        case .cancel:
            guard activation.isRecording else { break }
            activation.cancel(recordingWasActive: true)
            loudness.stop()
            await recorder?.cancel(closingSource: true)
            Self.log.notice("cancelled")
            conclude(.done)
        case .inputLost:
            Self.log.notice("input lost recording=\(self.activation.isRecording, privacy: .public)")
            await perform(activation.inputLost(), stoppingAt: nil)
        case .pasteLast:
            await writeLast()
        case .off:
            let recording = activation.isRecording
            activation.cancel(recordingWasActive: recording)
            if recording { await perform(.discard, stoppingAt: nil) }
        }
        armTimer()
        armEscape()
    }

    /// Paste last dictation, as Hex's recovery: never past a dictation under way, and with nothing kept, nothing.
    private func writeLast() async {
        guard !holdsDrop, !activation.isRecording, let text = lastTranscript else {
            return Self.log.notice("paste last refused busy=\(self.holdsDrop, privacy: .public) kept=\(self.lastTranscript != nil, privacy: .public)")
        }
        // Held as a dictation holds it, so Fix can't start on the draft this is about to change, nor this
        // write into one Fix is working on.
        guard drop.claim(busy: { [weak self] in self?.holdsDrop == true }) else {
            status(CorrectionSession.dropTaken)
            return Self.log.notice("paste last refused=dropHeld")
        }
        holdsDrop = true
        let ending = Self.ending(await insert(text))
        // Written: nothing to show. Otherwise the drop says why, as after a dictation.
        if ending == .done { holdsDrop = false } else { conclude(ending) }
    }

    /// Registers Escape for the recording under way, with the held shortcut's modifiers, or unregisters it.
    private func armEscape() {
        let chords = DictationEscape.modifiers(shortcut: shortcutModifiers(lastPressCleans), recording: activation.isRecording && holdsDrop,
                                               locked: activation.isRecordingLocked)
        guard chords != escapeChords else { return }
        escapeChords = chords
        escape(chords)
    }

    /// `stoppingAt` is the key event a stop ends the recording at: the release, or the press that ends a
    /// latched recording.
    private func perform(_ effect: DictationActivation.Effect?, stoppingAt instant: CaptureInstant?) async {
        switch effect {
        case .start?: await start(at: lastPress)
        case .stop?: stop(at: instant)
        case .discard?:
            loudness.stop()
            await recorder?.cancel()
            conclude(.done)
        case nil: break
        }
    }

    private func start(at pressed: CaptureInstant?) async {
        guard drop.claim(busy: { [weak self] in self?.holdsDrop == true }) else {
            status(CorrectionSession.dropTaken)
            activation.startResult(started: false)
            Self.log.notice("start refused=dropHeld")
            return
        }
        holdsDrop = true; turn += 1
        guard let engine, let recorder else { return refuse(.notInBuild) }
        guard let model = Self.modelURL(modelPath()) else { return refuse(.noModel) }
        language = languageHint(); plan = planCleanup(forced: lastPressCleans)
        if loadedModel != model {
            loadedModel = model
            loading = Task.detached(priority: .userInitiated) { try await engine.load(model: model) }
        }
        do { try await recorder.start(at: pressed) } catch {
            if case .microphoneAccess(.undetermined) = error { return ask() }
            return refuse(Self.failure(error))
        }
        activation.startResult(started: true)
        Self.log.notice("recording mode=\(self.activation.sessionMode.rawValue, privacy: .public)")
        loudness.start { recorder.inputLevel }
        drop.show(.recording)
    }

    private func refuse(_ failure: DictationFailure) {
        activation.startResult(started: false)
        Self.log.notice("start refused=\(String(describing: failure), privacy: .public)")
        conclude(.failed(failure))
    }

    /// The microphone was never asked for: this press asks and records nothing, since the prompt takes the
    /// keyboard and the answer comes long after the press. The drop then says to press again, or that access
    /// is off.
    private func ask() {
        activation.startResult(started: false)
        Self.log.notice("start refused=microphoneNeverAsked asking=\(!self.asking, privacy: .public)")
        drop.leave()
        holdsDrop = false
        guard !asking else { return }
        asking = true
        Task { [weak self] in
            guard let self else { return }
            let granted = await askMicrophone()
            asking = false
            // A dictation of its own may not be running, but Fix may have taken the drop meanwhile.
            guard !holdsDrop, drop.claim(busy: { false }) else { return }
            drop.show(granted ? .ready : .failed(.microphoneAccess))
        }
    }

    private func stop(at released: CaptureInstant?) {
        loudness.stop()
        drop.show(.transcribing)
        Task { [weak self] in
            guard let self else { return }
            let ending = await process(released: released)
            events.yield(.processed(ending))
        }
    }

    /// The drop leaves, or shows why nothing was written and leaves by itself; either way dictation lets it go.
    func conclude(_ ending: Ending) {
        switch ending {
        case .done: drop.leave()
        case .offer(let text): offer(text)
        case .failed(let failure): drop.show(.failed(failure))
        case .kept: drop.show(.kept, action: DropAction(symbol: "doc.on.doc", label: "Copy dictation") { [weak self] in self?.copyLast() })
        }
        holdsDrop = false
        if warmUpDeferred { warmUpDeferred = false; warmUp() }
    }

    /// Keeps exactly one timer, for the activation's current deadline.
    private func armTimer() {
        guard activation.deadline != armedFor else { return }
        timer?.cancel()
        armedFor = activation.deadline
        guard let deadline = armedFor else { return }
        timer = Task { [events] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            events.yield(.timer(deadline))
        }
    }

    private static func failure(_ error: DictationAudioError) -> DictationFailure {
        switch error {
        case .microphoneAccess: .microphoneAccess
        case .noInput, .unreadableFile, .failed: .noMicrophone
        }
    }
}
