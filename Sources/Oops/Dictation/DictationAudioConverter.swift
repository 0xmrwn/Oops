import AVFoundation
import OopsCore

/// Converts mono Float32 audio at a device's rate to the 16 kHz mono Float32 the speech engine takes, as it
/// streams, after Hex's `StreamingResampler`: the output starts with the first input sample (the converter
/// primes itself with silence rather than delaying the audio), and once finished it holds exactly as many
/// samples as converting the whole recording at once would. Audio already at 16 kHz passes through.
final class DictationAudioConverter {
    static let outputRate = Double(DictationCapture.sampleRate)

    let sourceRate: Double
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var sourceSamples = 0
    private var produced = 0
    private(set) var isFinished = false

    init(sourceRate: Double) throws(DictationAudioError) {
        guard sourceRate > 0,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false)
        else { throw .failed("no converter from \(sourceRate) Hz") }
        self.sourceRate = sourceRate; inputFormat = input; outputFormat = output
        guard sourceRate != Self.outputRate else { converter = nil; return }
        guard let converter = AVAudioConverter(from: input, to: output) else { throw .failed("no converter from \(sourceRate) Hz") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        // Normal priming treats the audio before the first sample as silence, so the output is not delayed.
        converter.primeMethod = .normal
        self.converter = converter
    }

    /// The 16 kHz audio `samples` complete. A few milliseconds stay inside the converter until more audio,
    /// or `finish`, follows them.
    func push(_ samples: [Float]) -> [Float] {
        guard !isFinished else { return [] }
        sourceSamples += samples.count
        let output = converter == nil ? samples : convert(samples, ending: false)
        produced += output.count
        return output
    }

    /// `push`, with the instant the newest output sample was captured, from that of the newest input sample.
    func push(_ samples: [Float], capturedThrough: CaptureInstant) -> (samples: [Float], capturedThrough: CaptureInstant) {
        let output = push(samples)
        return (output, outputThrough(capturedThrough))
    }

    /// Flushes the audio still inside the converter: the end of the recording. Nothing converts after it.
    func finish() -> [Float] {
        guard !isFinished else { return [] }
        isFinished = true
        guard converter != nil else { return [] }
        let expected = expectedSamples
        var output = convert([], ending: true)
        output.removeLast(max(0, min(output.count, produced + output.count - expected)))
        produced += output.count
        return output
    }

    /// How many output samples the input so far makes, converted whole.
    private var expectedSamples: Int { Int(Double(sourceSamples) * Self.outputRate / sourceRate) }

    /// When the newest output sample was captured, given that the newest input sample was at `inputThrough`:
    /// earlier by the audio still inside the converter.
    func outputThrough(_ inputThrough: CaptureInstant) -> CaptureInstant {
        let pending = max(0, expectedSamples - produced)
        return inputThrough.checkedSub(.nanoseconds(Int64(pending) * 1_000_000_000 / Int64(Self.outputRate))) ?? inputThrough
    }

    private func convert(_ samples: [Float], ending: Bool) -> [Float] {
        guard let converter else { return samples }
        var input: AVAudioPCMBuffer?
        if !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
           let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            input = buffer
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * Self.outputRate / sourceRate) + 1_024
        var output: [Float] = []
        let feed = InputFeed(buffer: input, ending: ending)
        while let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) {
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, status in feed.next(status) }
            if let channel = buffer.floatChannelData { output.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))) }
            // A full buffer may leave more behind; anything else means the input is used up.
            guard status == .haveData else { break }
        }
        return output
    }
}

/// Hands the converter one buffer, then says whether more may come.
private final class InputFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let ending: Bool

    init(buffer: AVAudioPCMBuffer?, ending: Bool) { self.buffer = buffer; self.ending = ending }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer {
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
        status.pointee = ending ? .endOfStream : .noDataNow
        return nil
    }
}
