import AppKit
import OopsCore
import QuartzCore

/// The loudness of a recording, 0 to 1, for a visualizer to read: sampled on every display frame from the
/// level the audio thread leaves in the ring's atomic, and smoothed (`DictationLoudness`). It runs only
/// while a recording does, and reads 0 otherwise.
@MainActor @Observable final class DictationLoudnessFeed {
    private(set) var level: Float = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var sample: (@Sendable () -> Float)?

    /// Starts following `source`, which returns the newest block's linear RMS level.
    func start(source: @escaping @Sendable () -> Float) {
        stop()
        sample = source
        let ticker = Ticker { [weak self] link in self?.tick(link.timestamp) }
        let link = (NSScreen.main ?? NSScreen.screens.first)?.displayLink(target: ticker, selector: #selector(Ticker.fire(_:)))
        link?.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops following and drops the level to 0.
    func stop() {
        link?.invalidate(); link = nil
        sample = nil; lastTimestamp = nil
        level = 0
    }

    private func tick(_ timestamp: CFTimeInterval) {
        guard let sample else { return }
        let dt = lastTimestamp.map { Float(timestamp - $0) } ?? 0
        lastTimestamp = timestamp
        let next = DictationLoudness.smoothed(level, toward: DictationLoudness.normalized(rms: sample()), dt: dt)
        if next != level { level = next }
    }

    /// The display link retains its target, so the feed is reached through a closure it holds weakly.
    private final class Ticker: NSObject {
        private let handler: @MainActor (CADisplayLink) -> Void
        init(_ handler: @escaping @MainActor (CADisplayLink) -> Void) { self.handler = handler }
        @MainActor @objc func fire(_ link: CADisplayLink) { handler(link) }
    }
}
