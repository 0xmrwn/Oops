import Foundation
import Synchronization

// A port of Hex's "Lower audio" ramp at v3.4.0 (MIT, github.com/anomalyco/hex): `src/audio/output_ducking.rs`.
// See THIRD_PARTY_NOTICES.md.

/// A set of volumes lowered and restored together, such as an output's channels, each between 0 and 1.
public protocol OutputVolume: AnyObject {
    func read() -> [Float]?
    func write(_ values: [Float]) -> Bool
}

/// "Lower audio" while dictating: a relative, channel-preserving volume ramp. Only the ramp's own thread waits
/// for restoration; the dictation and the UI never do.
enum OutputDucking {
    static let tick = 0.016
    static let epsilon: Float = 0.002
    /// Lowering starts after the 300 ms hold threshold, so it must finish before the speech that follows; a full
    /// second left the start of a dictation loud.
    static let lower = 0.12
    /// Restoring eases back over the original second so playback never jumps.
    static let restore = 1.0
    /// Bluetooth may acknowledge channels after the ramp ends; wait this much longer, then settle on whatever the
    /// output reports.
    static let settle = 0.5

    static func close(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < epsilon }
    }

    /// Lowers `output` until `stop`, then restores it.
    static func run(_ output: some OutputVolume, factor: Float, stop: DispatchSemaphore) {
        guard var ramp = DuckingRamp(output) else { return }
        ramp.retarget(factor)
        var started = ContinuousClock.now
        while stop.wait(timeout: .now() + tick) == .timedOut {
            ramp.tick(seconds(since: started))
            if ramp.finished { return }
        }
        ramp.retarget(nil)
        started = .now
        while !ramp.finished {
            ramp.tick(seconds(since: started))
            if !ramp.finished { Thread.sleep(forTimeInterval: tick) }
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

struct DuckingRamp<Output: OutputVolume> {
    let output: Output
    let original: [Float]
    private(set) var accepted: [Float]
    private(set) var from: [Float]
    private(set) var target: [Float]
    private(set) var restoring = false
    private(set) var settled = false
    private(set) var finished = false

    init?(_ output: Output) {
        guard let original = output.read(), !original.isEmpty else { return nil }
        self.output = output
        self.original = original
        accepted = original; from = original; target = original
    }

    /// Lowers to `factor` of the original volumes, or restores them when nil.
    mutating func retarget(_ factor: Float?) {
        if finished { return }
        if settled, !(output.read().map { OutputDucking.close($0, accepted) } ?? false) {
            finished = true // Respect manual changes after the hardware has settled.
            return
        }
        from = output.read() ?? accepted
        target = original.map { $0 * (factor ?? 1) }
        restoring = factor == nil
        settled = false
    }

    var duration: Double { restoring ? OutputDucking.restore : OutputDucking.lower }

    mutating func tick(_ seconds: Double) {
        if finished || settled { return }
        let t = min(max(seconds / duration, 0), 1)
        let eased = Float(t * t * (3 - 2 * t))
        let values = zip(from, target).map { from, target in from + (target - from) * eased }
        guard output.write(values), let actual = output.read() else { return rollback() }
        // Bluetooth may acknowledge channels late; use a bounded settling period.
        accepted = actual
        if t >= 1, OutputDucking.close(accepted, target) || seconds >= duration + OutputDucking.settle {
            settled = true
            finished = restoring
        }
    }

    private mutating func rollback() {
        _ = output.write(original)
        finished = true
    }
}

/// Holds the output lowered to `factor` of its volume until restored.
public final class OutputDuckingGuard: RecordingEnvironmentHold, Sendable {
    private let stop = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    private let restored = Mutex(false)

    private init() {}

    /// Lowers what `open` returns, opened on the ramp's own thread.
    public static func start(factor: Float, open: @escaping @Sendable () -> (any OutputVolume)?) -> OutputDuckingGuard {
        let held = OutputDuckingGuard()
        let stop = held.stop, done = held.done
        let thread = Thread {
            if let output = open() { OutputDucking.run(output, factor: factor, stop: stop) }
            done.signal()
        }
        thread.name = "output-ducking"
        thread.start()
        return held
    }

    /// Ramps the volume back and returns once it is restored.
    public func restore() {
        let first = restored.withLock { restored in
            defer { restored = true }
            return !restored
        }
        guard first else { return }
        stop.signal()
        done.wait()
    }

    deinit { restore() }
}
