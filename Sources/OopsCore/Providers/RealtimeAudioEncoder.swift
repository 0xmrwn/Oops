import Foundation

/// 16 kHz Float samples as the 24 kHz PCM16 the realtime service takes, in 100 ms base64 chunks. Linear
/// interpolation at input position `n × 2/3`; the last input sample and the phase carry across calls, so splitting
/// the input anywhere changes nothing.
public struct RealtimeAudioEncoder: Sendable {
    /// 100 ms at 24 kHz.
    public static let chunkSamples = 2_400

    private var last: Float?
    /// Where the next output sample sits, in thirds of an input sample after `last`.
    private var phase = 0
    private var pending: [Int16] = []

    public init() {}

    /// Every complete chunk the new samples finish.
    public mutating func encode(_ samples: [Float]) -> [String] {
        resample(samples)
        var chunks: [String] = []
        while pending.count >= Self.chunkSamples {
            chunks.append(Self.base64(pending[..<Self.chunkSamples]))
            pending.removeFirst(Self.chunkSamples)
        }
        return chunks
    }

    /// What is left after the last chunk, or nil. The outputs that fall past the final input sample hold its value,
    /// so a second of input is exactly a second of output.
    public mutating func flush() -> String? {
        if let last { while phase < 3 { pending.append(Self.pcm(last)); phase += 2 } }
        defer { pending = [] }
        return pending.isEmpty ? nil : Self.base64(pending[...])
    }

    private mutating func resample(_ samples: [Float]) {
        for sample in samples {
            guard let previous = last else { last = sample; pending.append(Self.pcm(sample)); phase = 2; continue }
            while phase < 3 {
                pending.append(Self.pcm(previous + (sample - previous) * Float(phase) / 3))
                phase += 2
            }
            phase -= 3
            last = sample
        }
    }

    private static func pcm(_ value: Float) -> Int16 {
        Int16((max(-1, min(1, value)) * 32_767).rounded())
    }

    private static func base64(_ samples: ArraySlice<Int16>) -> String {
        var data = Data(capacity: samples.count * 2)
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data.base64EncodedString()
    }
}
