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
@MainActor final class DictationSession {
    enum Event {
        case key(HotkeyPhase, CaptureInstant, ContinuousClock.Instant)
        /// The activation's deadline passed.
        case timer(ContinuousClock.Instant)
        /// A transcription is written or abandoned.
        case processed(Ending)
    }

    /// What a stopped recording came to.
    enum Ending: Equatable {
        /// Written, or nothing worth writing (no speech, an empty transcript): the drop just leaves.
        case done
        case failed(DictationFailure)
    }

    /// What each dictation came to, in numbers only: never what was said.
    static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Dictation")

    private(set) var activation = DictationActivation()
    /// Held from a start until its outcome shows or the drop leaves.
    private(set) var holdsDrop = false
    let recorder: DictationRecorder?
    let engine: any SpeechEngine?
    private let modelPath: @MainActor () -> String?
    private let mode: @MainActor () -> DictationMode
    let insert: @MainActor (String) async -> InsertOutcome
    private let drop: any DictationDrop
    private let status: @MainActor (String) -> Void
    private let events: AsyncStream<Event>.Continuation
    private var consumer: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var armedFor: ContinuousClock.Instant?
    /// The last key-down, where a recording starts, even one the activation remembered until a transcription
    /// finished: the open microphone keeps the audio since.
    private var lastPress: CaptureInstant?
    /// The last key-up, which a release deferred by the activation's grace still ends the recording at.
    private var lastRelease: CaptureInstant?
    /// The model this session loaded, or is loading or warming up, and that work.
    var loadedModel: URL?
    var loading: Task<Void, any Error>?

    /// `recorder` is nil, like `engine`, in a build without the speech engine, which may not touch the
    /// microphone. `modelPath` and `mode` are read at each start and press; `status` hears a refused start.
    init(recorder: DictationRecorder?, engine: any SpeechEngine?, modelPath: @escaping @MainActor () -> String?,
         mode: @escaping @MainActor () -> DictationMode, insert: @escaping @MainActor (String) async -> InsertOutcome,
         drop: any DictationDrop, status: @escaping @MainActor (String) -> Void) {
        self.recorder = recorder; self.engine = engine; self.modelPath = modelPath; self.mode = mode
        self.insert = insert; self.drop = drop; self.status = status
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        events = continuation
        consumer = Task { [weak self] in
            for await event in stream { await self?.handle(event) }
        }
    }

    /// The Dictate shortcut went down or up, at the instants the hotkey event was taken.
    func shortcut(_ phase: HotkeyPhase, at capture: CaptureInstant, now: ContinuousClock.Instant) {
        events.yield(.key(phase, capture, now))
    }

    /// Loads the model and runs it once at low priority, away from the main actor, so the first dictation
    /// doesn't wait for it. A failure is ignored: the first dictation loads it again.
    func warmUp() {
        guard let engine, loadedModel == nil, let model = Self.modelURL(modelPath()) else { return }
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
        switch event {
        case let .key(.pressed, capture, now):
            activation.mode = mode()
            lastPress = capture
            await perform(activation.pressed(at: now), stoppingAt: capture)
        case let .key(.released, capture, now):
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
        }
        armTimer()
    }

    /// `stoppingAt` is the key event a stop ends the recording at: the release, or the press that ends a
    /// latched recording.
    private func perform(_ effect: DictationActivation.Effect?, stoppingAt instant: CaptureInstant?) async {
        switch effect {
        case .start?: await start(at: lastPress)
        case .stop?: stop(at: instant)
        case .discard?:
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
        holdsDrop = true
        guard let engine, let recorder else { return refuse(.notInBuild) }
        guard let model = Self.modelURL(modelPath()) else { return refuse(.noModel) }
        if loadedModel != model {
            loadedModel = model
            loading = Task.detached(priority: .userInitiated) { try await engine.load(model: model) }
        }
        do { try await recorder.start(at: pressed) } catch { return refuse(Self.failure(error)) }
        activation.startResult(started: true)
        Self.log.notice("recording mode=\(self.activation.sessionMode.rawValue, privacy: .public)")
        drop.show(.recording)
    }

    private func refuse(_ failure: DictationFailure) {
        activation.startResult(started: false)
        Self.log.notice("start refused=\(String(describing: failure), privacy: .public)")
        conclude(.failed(failure))
    }

    private func stop(at released: CaptureInstant?) {
        drop.show(.transcribing)
        Task { [weak self] in
            guard let self else { return }
            let ending = await process(released: released)
            events.yield(.processed(ending))
        }
    }

    /// The drop leaves, or shows why nothing was written and leaves by itself; either way dictation lets it go.
    private func conclude(_ ending: Ending) {
        switch ending {
        case .done: drop.leave()
        case .failed(let failure): drop.show(.failed(failure))
        }
        holdsDrop = false
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
