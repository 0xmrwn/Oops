import Foundation

// The release tail, ported from Hex (github.com/anomalyco/hex, `src/dictation.rs` at 1b82cc0; MIT,
// Copyright (c) 2026 Christopher Langton): `ReleaseTail` and `DictationCapture::release_tail`.

/// Where a release's tail stands, from the audio recorded so far.
public enum ReleaseTail: Equatable, Sendable {
    /// More audio is needed. `growing` once speech has carried past `postReleaseTail`, so the wait is
    /// bounded by `maxReleaseTail` rather than the base tail.
    case waiting(growing: Bool)
    /// Finish keeping this much audio after the release.
    case through(Duration)

    /// The longest tail a wait in this state may still end with.
    public var bound: Duration {
        switch self {
        case .waiting(growing: true): DictationCapture.maxReleaseTail
        case .waiting(growing: false): DictationCapture.postReleaseTail
        case let .through(tail): tail
        }
    }
}

extension DictationCapture {
    /// How long after its own length a stop sound may still reach the microphone (output and input latency).
    static let stopToneMargin: Duration = .milliseconds(60)

    /// The tail a finish at `endedAt` keeps, judged on the audio recorded so far: `postReleaseTail`, or,
    /// while speech carries on past it, until `tailQuietFrames` of quiet or `maxReleaseTail`. Only
    /// sustained speech grows it, never a key click, and never a stop sound of `tone` length played from
    /// the release: speech must also be heard after the sound could have reached the microphone.
    public func releaseTail(endedAt: CaptureInstant, tone: Duration) -> ReleaseTail {
        guard let recording else { return .through(Self.postReleaseTail) }
        let through = recording.recordedThrough ?? endedAt
        if through < endedAt + Self.postReleaseTail { return .waiting(growing: false) }
        let voice = recording.voice
        let heard = voice.frames
        let capped = through >= endedAt + Self.maxReleaseTail
        let base = min(recording.frame(at: endedAt + Self.postReleaseTail), heard)
        if !voice.talkingUntil(base, from: 0) { return .through(Self.postReleaseTail) }
        // What runs into the base tail's end may be the stop sound; speech must carry on once it is over.
        let afterTone = tone == .zero ? 0 : recording.frame(at: endedAt + tone + Self.stopToneMargin)
        let decision = max(base, afterTone + VoiceTrack.tailSpeechFrames)
        if decision > recording.frame(at: endedAt + Self.maxReleaseTail) { return .through(Self.postReleaseTail) }
        if heard < decision { return capped ? .through(Self.postReleaseTail) : .waiting(growing: true) }
        if !voice.talkingUntil(decision, from: afterTone) { return .through(Self.postReleaseTail) }
        let tail = { (frame: Int) in min(max(recording.after(endedAt, frame: frame), Self.postReleaseTail), Self.maxReleaseTail) }
        switch voice.quietEnd(from: decision, end: heard) {
        case let end?: return .through(tail(end))
        case nil where capped: return .through(Self.maxReleaseTail)
        case nil: return .waiting(growing: true)
        }
    }
}
