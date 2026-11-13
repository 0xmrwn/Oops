import OopsCore

/// The microphone side of a dictation, and the one type a dictation session calls: `start` on the press,
/// `stop` on the release (or the second tap), `cancel` to drop a recording. Starting opens the source when
/// it is closed; the source then stays open for `keepAlive` after a recording ends, so a quick second
/// dictation loses no first syllable, and closes. Audio is drained from the source's ring every 10 ms,
/// converted to 16 kHz and laid on the capture timeline, which places the press and release exactly
/// whatever the block sizes and delays.
actor DictationRecorder {
    /// How long the source stays open after a recording ends.
    static let keepAlive: Duration = .seconds(10)
    /// How long past a tail's bound a stop waits for its audio, as Hex's release wait does.
    static let releaseGrace: Duration = .milliseconds(100)
    /// How often audio is taken from the ring: about one device period.
    static let drainInterval: Duration = .milliseconds(10)

    enum Outcome: Equatable, Sendable {
        /// 16 kHz mono audio from the press (and any pre-roll) through the release tail.
        case samples([Float])
        case discarded(Discard)
    }

    enum Discard: Equatable, Sendable {
        /// The level stayed below the silence threshold: nothing to write.
        case silence
        /// Every sample was exactly zero: the input runs but delivers nothing, as a muted or lost device does.
        case digitalSilence
        /// No audio arrived between the press and the end of the tail.
        case noAudio
        /// Nothing was recording, or the recording was cancelled while it stopped.
        case notRecording
    }

    private let source: any DictationAudioSource
    private let preRoll: Duration
    private let now: @Sendable () -> CaptureInstant
    private let keepAliveSleep: @Sendable (Duration) async throws -> Void
    private let ring = DictationAudioRing()
    private var capture = DictationCapture()
    /// Present while the source is open, until the source ends (a file played out).
    private var converter: DictationAudioConverter?
    private var isOpen = false
    /// When the newest block the source wrote was captured.
    private var sourceThrough: CaptureInstant?
    /// A press that came before the source's first block: the recording starts once the timeline is known.
    private var pendingPress: CaptureInstant?
    private var drainer: Task<Void, Never>?
    /// Changes with every start, cancel and finish, so a stop waiting for its tail notices it lost its recording.
    private var take = 0
    /// Changes with every start and scheduled close, so only the latest close acts.
    private var closeGeneration = 0
    /// A close is counting down the keep-alive since the last recording ended.
    private var closeScheduled = false
    /// Told when the input of a recording under way goes away (`DictationAudioSource.watchLoss`).
    private var inputLost: (@Sendable () -> Void)?
    /// The source's input went away: it brings no more audio, and the next start opens it again.
    private var lostSource = false

    /// `preRoll` is the audio kept from before each press (zero: the source opens on the press). `now`
    /// reads the clock key events share; `keepAliveSleep` waits out the keep-alive.
    init(source: any DictationAudioSource, preRoll: Duration = .zero, now: @escaping @Sendable () -> CaptureInstant = { .now() },
         keepAliveSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.source = source; self.preRoll = preRoll; self.now = now; self.keepAliveSleep = keepAliveSleep
    }

    /// Whether the source is open: recording, or keeping alive after a recording.
    var isSourceOpen: Bool { isOpen }

    var isRecording: Bool { capture.isRecording || pendingPress != nil }

    /// The newest block's RMS level, for the loudness a recording shows (`DictationLoudnessFeed`). Reads the
    /// ring's atomic, so any thread may call it without waiting for the actor.
    nonisolated var inputLevel: Float { ring.latestLevel }

    /// Starts recording at `pressedAt` (now when nil), opening the source if it is closed. Throws
    /// `.microphoneAccess` without asking when access is denied or was never asked. Does nothing while recording.
    func start(at pressedAt: CaptureInstant? = nil) throws(DictationAudioError) {
        let pressedAt = pressedAt ?? now()
        closeGeneration += 1
        closeScheduled = false
        guard !isRecording else { return }
        if isOpen, converter == nil || lostSource { closeSource() }
        if !isOpen { try openSource() }
        take += 1
        drain()
        if capture.capturedThrough == nil { pendingPress = pressedAt } else { capture.start(at: pressedAt, preRoll: preRoll) }
    }

    /// Finishes the recording at `releasedAt` (now when nil): waits for the release tail's audio, then hands
    /// over the clip, or why it was discarded. `tone` is the length of a stop sound played from the release,
    /// never taken for speech.
    func stop(at releasedAt: CaptureInstant? = nil, tone: Duration = .zero) async -> Outcome {
        let releasedAt = releasedAt ?? now()
        defer { scheduleClose() }
        guard isRecording else { return .discarded(.notRecording) }
        let take = take, waitStarted = ContinuousClock.now
        var tail: Duration
        while true {
            drain()
            guard take == self.take else { return .discarded(.notRecording) }
            let state: ReleaseTail = pendingPress == nil ? capture.releaseTail(endedAt: releasedAt, tone: tone) : .waiting(growing: false)
            if case let .through(through) = state { tail = through; break }
            // A source that ended will bring no more audio: finish with what came, as after a lost microphone.
            if converter == nil || lostSource { tail = DictationCapture.postReleaseTail; break }
            if ContinuousClock.now - waitStarted >= state.bound + Self.releaseGrace { tail = state.bound; break }
            try? await Task.sleep(for: Self.drainInterval)
        }
        pendingPress = nil
        self.take += 1
        guard case let .transcribe(clip) = capture.finish(endedAt: releasedAt, tail: tail), clip.durationMilliseconds > 0 else {
            return .discarded(.noAudio)
        }
        if clip.isDigitalSilence { return .discarded(.digitalSilence) }
        if clip.isNearSilent { return .discarded(.silence) }
        return .samples(clip.transcriptionSamples)
    }

    /// The recording's 16 kHz samples from `offset` on, once every block the source wrote is taken in: what a
    /// streaming engine hears while the key is still held. Empty when nothing records or nothing is new.
    func recorded(from offset: Int) -> [Float] {
        drain()
        return Array(capture.recordedSamples(from: offset))
    }

    /// Drops the recording, if any. `closingSource` closes the source at once rather than after the
    /// keep-alive: a cancel asked for silence, and the microphone goes with the recording.
    func cancel(closingSource: Bool = false) {
        if isRecording {
            capture.cancel()
            pendingPress = nil
            take += 1
        } else if !closingSource { return }
        guard closingSource else { return scheduleClose() }
        closeGeneration += 1
        if isOpen { closeSource() }
    }

    /// `handler` hears, from any thread, that a recording's input went away; what it captured is kept for
    /// `stop`, which finishes at once.
    func onInputLost(_ handler: @escaping @Sendable () -> Void) { inputLost = handler }

    /// The source ended its ring as its input went away: the audio it wrote is taken in, and a recording
    /// under way is told to stop. The next start opens the source again, on the current input.
    private func sourceLost() {
        drain()
        lostSource = isOpen
        if isRecording { inputLost?() }
    }

    private func openSource() throws(DictationAudioError) {
        ring.reset()
        source.watchLoss { [weak self] in Task { await self?.sourceLost() } }
        let rate = try source.open(into: ring)
        do { converter = try DictationAudioConverter(sourceRate: rate) } catch { source.close(); throw error }
        capture = DictationCapture()
        sourceThrough = nil
        isOpen = true
        drainer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                try? await Task.sleep(for: Self.drainInterval)
            }
        }
    }

    private func closeSource() {
        source.close()
        drainer?.cancel()
        drainer = nil
        ring.reset()
        converter = nil
        sourceThrough = nil
        capture = DictationCapture()
        pendingPress = nil
        closeScheduled = false
        lostSource = false
        isOpen = false
    }

    /// Lays every block the source has written on the timeline.
    private func drain() {
        guard let converter else { return }
        ring.drain { block, through in
            // The seam for a level meter: each block here is one device period (about 10 ms), mono, at the
            // device's rate, as it was captured.
            let (samples, capturedThrough) = converter.push(block, capturedThrough: through)
            ingest(samples, capturedThrough: capturedThrough)
            sourceThrough = through
        }
        if ring.isEnded, let sourceThrough {
            // The file played out: flush the converter, so the recording keeps its last milliseconds.
            let flushed = converter.finish()
            ingest(flushed, capturedThrough: converter.outputThrough(sourceThrough))
            self.converter = nil
        }
    }

    private func ingest(_ samples: [Float], capturedThrough: CaptureInstant) {
        capture.ingest(samples, capturedThrough: capturedThrough)
        if let pressedAt = pendingPress {
            pendingPress = nil
            capture.start(at: pressedAt, preRoll: preRoll)
        }
    }

    /// Closes the source once it has been idle for `keepAlive`, unless a recording starts first.
    private func scheduleClose() {
        guard isOpen, !isRecording, !closeScheduled else { return }
        closeScheduled = true
        closeGeneration += 1
        let generation = closeGeneration, sleep = keepAliveSleep
        Task {
            try? await sleep(Self.keepAlive)
            closeIfIdle(generation)
        }
    }

    private func closeIfIdle(_ generation: Int) {
        guard generation == closeGeneration, !isRecording, isOpen else { return }
        closeScheduled = false
        closeSource()
    }
}
