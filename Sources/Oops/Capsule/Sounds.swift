import AVFoundation
import AppKit
import OopsCore

/// Plays the drop's three cues, each scheduled on the audio clock to land
/// on the drop's motion, so a busy main thread (a paste, an Accessibility call) can't push it late.
/// The engine runs only around a correction: warmed on the shortcut, stopped a few seconds after
/// the last cue.
@MainActor final class Sounds {
    static let shared = Sounds()
    /// On unless turned off; `bool(forKey:)` also reads a `-SoundsEnabled NO` launch argument.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "SoundsEnabled") == nil || UserDefaults.standard.bool(forKey: "SoundsEnabled") }
    /// The delays count from the frame that draws the state change, one display frame after it.
    private static let displayLag = 1.0 / 60
    private let engine = AVAudioEngine()
    /// Two voices, so a cue can ring while the next one starts.
    private let voices = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var voice = 0
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var cycle = TakeCycle()
    private var sleep: Task<Void, Never>?
    private let probe = SoundProbe.fromDefaults()

    private init() {
        for cue in SoundCue.allCases {
            for take in 0..<cue.takes {
                let name = cue.file(take: take)
                guard let url = Bundle.main.url(forResource: name, withExtension: "caf", subdirectory: "Sounds"),
                      let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil else { continue }
                buffers[name] = buffer
            }
        }
        guard let format = buffers.values.first?.format else { return }
        for node in voices { engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format) }
        probe?.listen(to: engine)
        // A new output device (or another app taking this one) stops the engine; the next cue restarts it.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.voices.forEach { $0.stop() } }
        }
    }

    /// Wakes the output ahead of a correction, so the start cue's lead isn't spent starting the engine.
    func warm() {
        guard Self.enabled, start() else { return }
        idle(after: 3)
    }

    /// Plays `cue` `delay` seconds after the frame that draws the change it answers.
    func play(_ cue: SoundCue, after delay: Double) {
        guard Self.enabled, start() else { return }
        let take = cycle.next(cue)
        guard let buffer = buffers[cue.file(take: take)] else { return }
        let node = voices[voice]; voice = (voice + 1) % voices.count
        // The device's own latency is taken off, so the delay is when the cue is heard.
        let lead = max(0, Self.displayLag + delay - engine.outputNode.presentationLatency)
        let now = mach_absolute_time()
        node.scheduleBuffer(buffer, at: AVAudioTime(hostTime: now + AVAudioTime.hostTime(forSeconds: lead)))
        if !node.isPlaying { node.play() }
        probe?.scheduled(cue, take: take, anchor: now, heard: Self.displayLag + delay)
        idle(after: Self.displayLag + delay + Double(buffer.frameLength) / buffer.format.sampleRate + 2)
    }

    /// Settings → Play audio cues: what turning it on sounds like.
    func preview() { play(.success, after: 0.05) }

    private func start() -> Bool {
        guard !buffers.isEmpty else { return false }
        if engine.isRunning { return true }
        engine.prepare()
        do { try engine.start() } catch { return false }
        return true
    }
    private func idle(after seconds: Double) {
        sleep?.cancel()
        sleep = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.voices.forEach { $0.stop() }
            self.engine.stop()
        }
    }
}

/// Debug-only: `-SoundProbe <path>` writes a JSON line per cue: when it was meant to be heard and
/// when the mixer actually rendered its onset (plus the device latency), both in ms after the
/// state change. Checks the scheduling without ears; the picture side comes from a recording.
private final class SoundProbe: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var pending: [(cue: SoundCue, take: Int, anchor: UInt64, heard: Double)] = []
    private var lastLoud: UInt64 = 0
    private var latency = 0.0
    private init(url: URL) { self.url = url }
    static func fromDefaults() -> SoundProbe? {
        DebugFlags.soundProbe.map { SoundProbe(url: $0) }
    }
    func listen(to engine: AVAudioEngine) {
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 512, format: mixer.outputFormat(forBus: 0)) { [weak self] buffer, when in
            guard let self, when.isHostTimeValid, let samples = buffer.floatChannelData?[0] else { return }
            let rate = buffer.format.sampleRate
            for i in 0..<Int(buffer.frameLength) where abs(samples[i]) > 0.003 {   // -50 dBFS
                let at = when.hostTime + AVAudioTime.hostTime(forSeconds: Double(i) / rate)
                // An onset is the first loud sample after 50 ms of quiet.
                if at > self.lastLoud + AVAudioTime.hostTime(forSeconds: 0.05) { self.onset(at) }
                self.lastLoud = at
            }
        }
        latency = engine.outputNode.presentationLatency
    }
    func scheduled(_ cue: SoundCue, take: Int, anchor: UInt64, heard: Double) {
        lock.lock(); pending.append((cue, take, anchor, heard)); lock.unlock()
    }
    private func onset(_ at: UInt64) {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return }
        let cue = pending.removeFirst(); lock.unlock()
        let rendered = AVAudioTime.seconds(forHostTime: at - cue.anchor) + latency
        let line = String(format: #"{"cue":"%@","take":%d,"meant_ms":%.1f,"heard_ms":%.1f,"latency_ms":%.1f}"#,
                          cue.cue.rawValue, cue.take + 1, cue.heard * 1000, rendered * 1000, latency * 1000) + "\n"
        let url = self.url
        DispatchQueue.main.async {
            if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            else { try? Data(line.utf8).write(to: url) }
        }
    }
}
