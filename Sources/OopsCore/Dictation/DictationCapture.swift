import Foundation

// A dictation's recording on the microphone timeline, ported from Hex (github.com/anomalyco/hex,
// `src/dictation.rs` at 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton): `DictationCapture`, its
// `Recording`, and the constants they read. Hex resamples inside the recording; Oops converts the
// microphone to 16 kHz before the capture sees it, so everything here is 16 kHz audio.

/// The audio timeline of an open microphone and the recording on it. Audio arrives in timestamped blocks
/// (`ingest`); a recording starts at a press instant, keeping `preRoll` of the audio before it, and
/// finishes at a release instant, keeping the release tail and dropping whatever came after it. The press
/// may lie behind the newest audio (the press was handled late) or ahead of it (the microphone has not yet
/// handed over what it heard): either way the recording starts exactly at the press boundary.
public struct DictationCapture: Sendable {
    /// The rate of every sample the capture holds and hands on: what the speech engine takes.
    public static let sampleRate = 16_000
    /// Audio kept after a release that finishes a capture, because a release often lands while the last
    /// word is still sounding.
    public static let postReleaseTail: Duration = .milliseconds(200)
    /// The longest a release tail grows while speech carries on past `postReleaseTail` (a word still being
    /// said as the shortcut goes up).
    public static let maxReleaseTail: Duration = .milliseconds(600)
    /// The pre-roll a microphone kept open ahead of the press can give: the start of a word said with the press.
    public static let readyPreRoll: Duration = .milliseconds(450)
    /// How much past audio the timeline keeps for a recording's pre-roll and for a press handled late.
    static let timelineBufferDuration: Duration = .seconds(10)
    static let initialRecordingCapacity: Duration = .seconds(10)

    public enum Finish: Sendable {
        /// Nothing was recording.
        case discard
        case transcribe(DictationClip)
    }

    var ring = TimelineRing()
    var ringCapturedThrough: CaptureInstant?
    var recording: Recording?

    public init() {}

    public var isRecording: Bool { recording != nil }

    /// When the active recording started, without its pre-roll.
    public var startedAt: CaptureInstant? { recording?.startedAt }

    /// When the newest audio on the timeline was captured; nil until the first block arrives.
    public var capturedThrough: CaptureInstant? { ringCapturedThrough }

    /// Starts a recording at `pressedAt`, which may lie past the newest audio: a microphone that delivers
    /// large blocks, or one just opened, has not yet handed over what it captured around the press. Exactly
    /// `preRoll` before the press is kept, however large the blocks; what precedes it in audio still to
    /// arrive is dropped as it comes.
    public mutating func start(at pressedAt: CaptureInstant, preRoll: Duration) {
        guard let through = ringCapturedThrough else { return startWithPreRoll(pressedAt, duration: preRoll) }
        guard let ahead = pressedAt.checkedDuration(since: through) else { return startFromTimeline(pressedAt, preRoll: preRoll) }
        startWithPreRoll(pressedAt, duration: preRoll.saturatingSub(ahead))
        recording?.prePress += min(ahead, preRoll)
        recording?.skipSamples = samplesFor(ahead.saturatingSub(preRoll), sampleRate: Self.sampleRate)
        recording?.recordedThrough = through
        recording?.pressLeadMilliseconds = signedMilliseconds(through, pressedAt)
    }

    /// Starts at `occurredAt`, at or behind the newest audio, keeping `preRoll` before it: the audio
    /// already past it is taken back out of the timeline, so a press handled late loses nothing.
    mutating func startFromTimeline(_ occurredAt: CaptureInstant, preRoll: Duration) {
        let delayedAudio = ringCapturedThrough.flatMap { $0.checkedDuration(since: occurredAt) } ?? .zero
        startWithPreRoll(occurredAt, duration: preRoll + delayedAudio)
        guard let through = ringCapturedThrough, var recording else { return }
        recording.recordedThrough = through
        recording.prePress = recording.prePress.saturatingSub(delayedAudio)
        recording.pressLeadMilliseconds = signedMilliseconds(through, occurredAt)
        self.recording = recording
    }

    mutating func startWithPreRoll(_ now: CaptureInstant, duration: Duration) {
        let preRoll = min(samplesFor(duration, sampleRate: Self.sampleRate), ring.count)
        var recording = Recording(startedAt: now)
        recording.prePress = durationForFrames(preRoll, sampleRate: Self.sampleRate)
        recording.push(ring.suffix(preRoll))
        recording.trackVoice()
        self.recording = recording
    }

    /// Adds a block of 16 kHz audio whose last sample was captured at `capturedThrough`.
    public mutating func ingest(_ samples: [Float], capturedThrough: CaptureInstant) {
        recording?.pushThrough(samples[...], capturedThrough: capturedThrough)
        keepWarm(samples[...], retention: Self.timelineBufferDuration)
        ringCapturedThrough = capturedThrough
    }

    mutating func keepWarm(_ samples: ArraySlice<Float>, retention: Duration) {
        let capacity = samplesFor(retention, sampleRate: Self.sampleRate)
        if samples.count >= capacity {
            ring.clear()
            ring.append(samples.suffix(capacity))
            return
        }
        ring.dropFirst(max(0, ring.count + samples.count - capacity))
        ring.append(samples)
    }

    /// The active recording's samples from `offset` on, for a stream that hears it as it grows: they are only ever
    /// appended, so what was read before stays in place, and `finish` cuts only past the release tail. Empty when
    /// nothing records or nothing is new.
    public func recordedSamples(from offset: Int) -> ArraySlice<Float> {
        guard let samples = recording?.samples else { return [] }
        return samples[min(max(offset, 0), samples.count)...]
    }

    /// Drops the active recording.
    public mutating func cancel() { recording = nil }

    /// Finishes at the exact `endedAt` event, keeping audio through `endedAt + tail`.
    public mutating func finish(endedAt: CaptureInstant, tail: Duration) -> Finish {
        guard let recording else { return .discard }
        self.recording = nil
        let keptTail = recording.recordedThrough.flatMap { $0.checkedDuration(since: endedAt) }.map { min($0, tail) } ?? .zero
        let timeline = ClipTimeline(pressLeadMilliseconds: recording.pressLeadMilliseconds,
                                    releaseLeadMilliseconds: recording.recordedThrough.map { signedMilliseconds($0, endedAt) },
                                    maxChunkGap: recording.maxChunkGap)
        let prePress = recording.prePress
        let samples = recording.finish(endedAt: endedAt + tail)
        return .transcribe(DictationClip(samples: samples,
                                         tailSamples: min(samplesFor(keptTail, sampleRate: Self.sampleRate), samples.count),
                                         pressSamples: min(samplesFor(prePress, sampleRate: Self.sampleRate), samples.count),
                                         timeline: timeline))
    }
}

/// The recording between a press and its release, in 16 kHz samples.
struct Recording: Sendable {
    let startedAt: CaptureInstant
    var samples: [Float] = []
    var sourceSamples = 0
    var recordedThrough: CaptureInstant?
    /// How much of the recording precedes the press.
    var prePress: Duration = .zero
    /// Samples still to arrive that precede the pre-roll, dropped as they come (a press ahead of the newest audio).
    var skipSamples = 0
    var pressLeadMilliseconds: Int64?
    var maxChunkGap: Duration = .zero
    var voice = VoiceTrack()

    init(startedAt: CaptureInstant) {
        self.startedAt = startedAt
        samples.reserveCapacity(samplesFor(DictationCapture.initialRecordingCapacity, sampleRate: DictationCapture.sampleRate))
    }

    mutating func push(_ samples: ArraySlice<Float>) {
        sourceSamples += samples.count
        self.samples.append(contentsOf: samples)
    }

    mutating func pushThrough(_ samples: ArraySlice<Float>, capturedThrough: CaptureInstant) {
        if let previous = recordedThrough {
            let capturedFrom = capturedThrough.subFrames(samples.count, sampleRate: DictationCapture.sampleRate)
            maxChunkGap = max(maxChunkGap, capturedFrom.duration(since: previous))
        }
        let skip = min(skipSamples, samples.count)
        skipSamples -= skip
        push(samples.dropFirst(skip))
        trackVoice()
        recordedThrough = capturedThrough
    }

    /// Classifies the audio the voice track has not seen.
    mutating func trackVoice() {
        voice.extend(samples[min(voice.consumed, samples.count)...])
    }

    /// The 20 ms clip frame `at` falls in.
    func frame(at instant: CaptureInstant) -> Int {
        samplesFor(prePress + instant.duration(since: startedAt), sampleRate: DictationCapture.sampleRate) / VoiceTrack.frame
    }

    /// How far past `endedAt` clip frame `frame` begins.
    func after(_ endedAt: CaptureInstant, frame: Int) -> Duration {
        durationForFrames(frame * VoiceTrack.frame, sampleRate: DictationCapture.sampleRate).saturatingSub(prePress + endedAt.duration(since: startedAt))
    }

    /// The recording's samples, without what was captured after `endedAt`.
    consuming func finish(endedAt: CaptureInstant?) -> [Float] {
        if let endedAt, let recordedThrough, let postRelease = recordedThrough.checkedDuration(since: endedAt) {
            sourceSamples = max(0, sourceSamples - samplesFor(postRelease, sampleRate: DictationCapture.sampleRate))
        }
        if samples.count > sourceSamples { samples.removeLast(samples.count - sourceSamples) }
        return samples
    }
}

/// The timeline's recent audio: appended at the back, dropped from the front, read from the back.
struct TimelineRing: Sendable {
    private var storage: [Float] = []
    private var head = 0

    var count: Int { storage.count - head }
    var first: Float? { head < storage.count ? storage[head] : nil }
    var last: Float? { head < storage.count ? storage.last : nil }

    mutating func clear() { storage.removeAll(keepingCapacity: true); head = 0 }

    mutating func dropFirst(_ count: Int) {
        head += min(count, self.count)
        // Compacts once the dropped front outweighs what is kept, so each sample moves about once.
        if head > 0, head >= storage.count - head { storage.removeFirst(head); head = 0 }
    }

    mutating func append(_ samples: ArraySlice<Float>) { storage.append(contentsOf: samples) }

    func suffix(_ count: Int) -> ArraySlice<Float> { storage[(storage.count - min(count, self.count))...] }
}
