#if DEBUG
import AppKit
import QuartzCore

/// Debug-only frame-pacing probe for the perf harness: a display link on the main run loop that
/// records when each frame's callback actually ran. A busy main thread delivers callbacks late or
/// skips them, which is what a user sees as a hitch. Writes a few kilobytes of JSON, instead of
/// the gigabytes a system-wide Instruments trace leaves behind.
@MainActor final class FramePacer: NSObject {
    /// The running probe, so a harness can mark the moment it changes something.
    weak static var current: FramePacer?
    private var link: CADisplayLink?
    private var mark: CFTimeInterval?
    private var reactions: [Double] = []
    private var start: CFTimeInterval = 0, last: CFTimeInterval = 0
    private var deltas: [Double] = []
    private var late: [(at: Double, ms: Double)] = []
    private var budget: Double = 1.0 / 60
    private var cpuStart = FramePacer.cpuSeconds()

    func begin(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        cpuStart = Self.cpuSeconds()
        Self.current = self
    }

    /// Call right before a change (a tab switch): the summary reports how long the main thread
    /// took to deliver the next frame after it, the delay a click is felt with.
    func markChange() { mark = CACurrentMediaTime(); marks.append(CACurrentMediaTime() - start) }
    private var marks: [Double] = []

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        budget = max(link.duration, 1.0 / 240)
        if start == 0 { start = now } else {
            let delta = now - last
            deltas.append(delta)
            if delta > budget * 1.5 { late.append((now - start, delta * 1000)) }
        }
        last = now
        if let mark { reactions.append((now - mark) * 1000); self.mark = nil }
    }

    /// Writes the summary and stops: frames, frames missed (each late callback counts the vsyncs
    /// it skipped), worst frame, the 99th percentile and the process's CPU share.
    func finish(writingTo url: URL) {
        link?.invalidate(); link = nil
        let wall = max(last - start, 0.001)
        let missed = deltas.reduce(0) { $0 + max(Int(($1 / budget).rounded()) - 1, 0) }
        let sorted = deltas.sorted()
        let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let report: [String: Any] = [
            "seconds": wall, "refreshHz": (1 / budget).rounded(), "frames": deltas.count, "missedFrames": missed,
            "worstMs": (sorted.last ?? 0) * 1000, "p99Ms": p99 * 1000,
            "cpuPercent": 100 * (Self.cpuSeconds() - cpuStart) / wall,
            "reactionMs": reactions.map { $0.rounded() },
            "marks": marks.map { ($0 * 1000).rounded() / 1000 },
            "late": late.prefix(200).map { ["at": ($0.at * 1000).rounded() / 1000, "ms": $0.ms.rounded()] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
#endif
