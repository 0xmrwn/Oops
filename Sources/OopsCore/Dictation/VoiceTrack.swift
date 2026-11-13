import Foundation

// The release tail's speech history, ported from Hex (github.com/anomalyco/hex, `src/dictation.rs` at
// 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton): `VoiceTrack` and the tail's frame constants.

/// Speech flags of a recording's 16 kHz audio, one per 20 ms frame, against the adaptive noise floor of
/// `SpeechFrames`. Only recent frames are kept.
struct VoiceTrack: Sendable {
    static let frame = SpeechFrames.frameSamples
    /// Speech frames in a row (20 ms each) that count as still talking: a key click is far shorter.
    static let tailSpeechFrames = 5
    /// Quiet frames in a row that end a growing tail (160 ms).
    static let tailQuietFrames = 8
    /// Quiet frames a run of speech may skip over, as between syllables.
    static let tailSpeechGapFrames = 2
    /// 20 ms frames of recent speech flags kept for the release tail.
    static let historyFrames = 150

    private var speech = SpeechFrames()
    private var pending: [Float] = []
    /// Clip samples classified or waiting in `pending`.
    private(set) var consumed = 0
    private var flags: [Bool] = []
    /// The frame index of `flags[0]`.
    private(set) var first = 0

    mutating func extend(_ samples: ArraySlice<Float>) {
        consumed += samples.count
        var samples = samples
        while !samples.isEmpty {
            let take = min(samples.count, Self.frame - pending.count)
            pending.append(contentsOf: samples.prefix(take))
            samples = samples.dropFirst(take)
            if pending.count == Self.frame {
                flags.append(speech.isSpeech(pending))
                pending.removeAll(keepingCapacity: true)
                if flags.count > Self.historyFrames {
                    flags.removeFirst()
                    first += 1
                }
            }
        }
    }

    /// Frames classified so far.
    var frames: Int { first + flags.count }

    func isSpeech(_ frame: Int) -> Bool {
        let index = frame - first
        return index >= 0 && index < flags.count && flags[index]
    }

    /// Whether speech runs up to frame `end` (exclusive): its last speech frame is within a syllable gap of
    /// `end`, and at least `tailSpeechFrames` speech frames, none before `from`, lead up to it with no gap
    /// longer than a syllable's.
    func talkingUntil(_ end: Int, from: Int) -> Bool {
        var speech = 0, gap = 0, frame = end
        while frame > max(from, first) {
            frame -= 1
            if isSpeech(frame) {
                speech += 1
                gap = 0
                if speech >= Self.tailSpeechFrames { return true }
            } else {
                gap += 1
                if gap > Self.tailSpeechGapFrames { return false }
            }
        }
        return false
    }

    /// The first frame at or after `from`, before `end`, that ends `tailQuietFrames` quiet frames in a row.
    func quietEnd(from: Int, end: Int) -> Int? {
        var quiet = 0
        for frame in from ..< max(from, end) {
            if isSpeech(frame) {
                quiet = 0
            } else {
                quiet += 1
                if quiet == Self.tailQuietFrames { return frame + 1 }
            }
        }
        return nil
    }
}
