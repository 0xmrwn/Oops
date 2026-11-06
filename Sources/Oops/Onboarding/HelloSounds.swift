import AVFoundation
import Foundation

/// Hello's own sounds (design/onboarding/sound/make.py): keystrokes, the pull-back's air swell and the
/// wave's notes, the drop's voice transposed up E major. The app's three cues stay with `Sounds`;
/// these play only here. Keys and the wave overlap, hence a small pool of voices rather than two.
@MainActor final class HelloSounds {
    enum Sound: Hashable { case key, space, swell, waveStart(Int), waveSuccess(Int) }
    private static let keyTakeCount = 12
    private static let keyNames = Set((1...keyTakeCount).map { "key-\($0)" })
    private let engine = AVAudioEngine()
    private let voices = (0..<10).map { _ in AVAudioPlayerNode() }
    private var voice = 0
    private var cueID = 0
    private var playing: [Int: Int] = [:]
    private var finishing = false
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    /// Keys never repeat a take back to back: a repeated sample is what makes typing sound fake.
    private var lastTake: [String: Int] = [:]

    init(onlyKeyClicks: Bool = false) {
        let urls = Bundle.main.urls(forResourcesWithExtension: "caf", subdirectory: "Sounds/Onboarding") ?? []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            guard !onlyKeyClicks || Self.keyNames.contains(name),
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { continue }
            buffers[name] = buffer
        }
        guard let format = buffers.values.first?.format else { return }
        for node in voices { engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format) }
    }

    func play(_ sound: Sound, gain: Float = 1) {
        guard Sounds.enabled, let name = file(sound), let buffer = buffers[name] else { return }
        if !engine.isRunning {
            playing.removeAll()
            engine.prepare(); guard (try? engine.start()) != nil else { return }
        }
        finishing = false
        let index = voice
        let node = voices[index]
        voice = (index + 1) % voices.count
        cueID &+= 1
        let id = cueID
        playing[index] = id
        node.volume = gain
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            // Stopping the engine inside the audio callback can deadlock.
            Task { @MainActor in
                guard let self, self.playing[index] == id else { return }
                self.playing[index] = nil
                self.stopIfDrained()
            }
        }
        if !node.isPlaying { node.play() }
    }

    /// A step can end mid-cue. Let the device play its tail before stopping.
    func finish() {
        finishing = true
        stopIfDrained()
    }

    private func stopIfDrained() {
        if finishing, playing.isEmpty, engine.isRunning { stop() }
    }

    func stop() {
        finishing = false; playing.removeAll()
        voices.forEach { $0.stop() }; engine.stop()
    }

    private func file(_ sound: Sound) -> String? {
        switch sound {
        case .key: take("key", of: Self.keyTakeCount)
        case .space: take("key-space", of: 4)
        case .swell: "whoosh-long-1"
        case let .waveStart(step): "wave-start-\(step)"
        case let .waveSuccess(step): "wave-success-\(step)"
        }
    }

    private func take(_ name: String, of count: Int) -> String {
        var next = Int.random(in: 1...count)
        while next == lastTake[name] { next = Int.random(in: 1...count) }
        lastTake[name] = next
        return "\(name)-\(next)"
    }
}
