import Foundation

// Speech flags over 16 kHz audio, ported from Hex (github.com/anomalyco/hex,
// `src/transcription/pause_segmenter.rs` at 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton):
// `SpeechFrames`, `FrameLevel` and their constants.
//
// Speech is any 20 ms frame at least 12 dB above an adaptive noise floor and never quieter than -55 dBFS.
// The floor starts at the first frame, falls immediately, and rises slowly, so speech between word gaps
// cannot drag it up to the speech level.

/// One frame against the noise floor. A frame can be neither quiet nor speech, but never both.
struct FrameLevel: Equatable {
    /// The frame sits at the noise floor (within the quiet margin) or below the quiet minimum. Stricter
    /// than "not speech": speech only a few dB above steady room noise, or from a quiet microphone, is
    /// not quiet.
    var quiet: Bool
    var speech: Bool
}

/// Classifies consecutive 20 ms frames of 16 kHz audio as speech or not against the adaptive noise floor.
struct SpeechFrames: Sendable {
    static let frameSamples = DictationCapture.sampleRate / 50
    static let speechMarginDB: Float = 12
    /// How far above the floor a frame may sit and still count as quiet.
    static let quietMarginDB: Float = 4
    static let minimumSpeechDB: Float = -55
    /// Below this a frame is quiet whatever the floor. Lower than the speech minimum: a quiet built-in
    /// microphone can carry whole dictations under -55 dBFS.
    static let quietMinimumDB: Float = -70
    static let lowestFloorDB: Float = -90
    /// About 3 dB per second at 50 frames per second.
    static let floorRiseDBPerFrame: Float = 0.06

    private var floorDB: Float?

    /// Whether `frame`, the next `frameSamples` samples, is speech.
    mutating func isSpeech(_ frame: [Float]) -> Bool { classify(frame).speech }

    /// How `frame`, the next `frameSamples` samples, sits against the noise floor.
    mutating func classify(_ frame: [Float]) -> FrameLevel {
        let (level, floor) = measure(frame)
        return FrameLevel(quiet: level <= max(floor + Self.quietMarginDB, Self.quietMinimumDB),
                          speech: level > max(floor + Self.speechMarginDB, Self.minimumSpeechDB))
    }

    /// The frame's DC-removed level and the noise floor after it, both in dBFS. Some microphones carry a
    /// DC offset far louder than the speech on it; counted as level, it would pin every frame to the floor.
    private mutating func measure(_ frame: [Float]) -> (level: Float, floor: Float) {
        let count = Float(frame.count)
        let mean = frame.reduce(0, +) / count
        let energy = frame.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / count
        let level: Float = energy.isFinite ? 10 * log10(max(energy, 1e-18)) : 0
        let floor: Float = if let floorDB, level >= floorDB { floorDB + Self.floorRiseDBPerFrame } else { max(level, Self.lowestFloorDB) }
        floorDB = floor
        return (level, floor)
    }
}
