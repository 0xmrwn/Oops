import Foundation
import OopsCore
import Testing

/// 16 kHz Float to the 24 kHz PCM16 the realtime service takes.
struct RealtimeTranscriptionEncoderTests {
    private func encodeAll(_ pieces: [[Float]]) -> [Data] {
        var encoder = RealtimeAudioEncoder()
        var chunks = pieces.flatMap { encoder.encode($0) }
        if let rest = encoder.flush() { chunks.append(rest) }
        return chunks.compactMap { Data(base64Encoded: $0) }
    }

    private func samples(_ chunks: [Data]) -> [Int16] {
        chunks.flatMap { chunk in
            stride(from: 0, to: chunk.count, by: 2).map { Int16(bitPattern: UInt16(chunk[$0]) | UInt16(chunk[$0 + 1]) << 8) }
        }
    }

    @Test func `one second at 16 kHz becomes one second at 24 kHz`() {
        let chunks = encodeAll([[Float](repeating: 0.1, count: 16_000)])
        #expect(samples(chunks).count == 24_000)
    }

    @Test func `chunks are a hundred milliseconds of little-endian PCM16`() {
        let chunks = encodeAll([[Float](repeating: 0.5, count: 16_000)])
        #expect(chunks.count == 10)
        #expect(chunks.allSatisfy { $0.count == 4_800 })
        // 0.5 × 32,767 rounds to 16,384 = 0x4000, low byte first.
        #expect(Array(chunks[0].prefix(2)) == [0x00, 0x40])
    }

    @Test func `the remainder is flushed once`() {
        var encoder = RealtimeAudioEncoder()
        #expect(encoder.encode([Float](repeating: 0.1, count: 1_000)).isEmpty)
        #expect(encoder.flush().flatMap { Data(base64Encoded: $0) }?.count == 3_000)
        #expect(encoder.flush() == nil)
    }

    @Test func `interpolation lands between neighbours and the tail holds the last sample`() {
        let out = samples(encodeAll([[0, 0.3, 0.6, 0.9]]))
        let expected: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 0.9]
        #expect(out.count == expected.count)
        for (value, want) in zip(out, expected) { #expect(abs(Double(value) - want * 32_767) <= 1) }
    }

    @Test func `samples outside one are clamped`() {
        #expect(samples(encodeAll([[2, -3]])).prefix(1) == [32_767])
        #expect(samples(encodeAll([[-3, -3]])).prefix(1) == [-32_767])
    }

    @Test func `splitting the input changes nothing`() {
        let signal = (0..<10_001).map { sin(Float($0) * 0.013) * 0.8 }
        let whole = encodeAll([signal])
        var pieces: [[Float]] = [], index = 0, size = 1
        while index < signal.count {
            pieces.append(Array(signal[index..<min(index + size, signal.count)]))
            index += size; size = size * 3 % 977 + 1
        }
        #expect(samples(encodeAll(pieces)) == samples(whole))
    }
}
