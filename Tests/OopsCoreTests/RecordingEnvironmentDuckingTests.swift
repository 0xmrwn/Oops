import Foundation
@testable import OopsCore
import Synchronization
import Testing

// Ported from the tests of Hex's `src/audio/output_ducking.rs` at v3.4.0, over a fake output.

/// An output whose channels keep three decimals, as hardware rounds them. `fail` makes the next write set only
/// the first channel and report failure.
final class FakeOutput: OutputVolume, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float]
    var fail = false

    init(_ values: [Float]) { stored = values }

    /// What the output plays at now; setting it is a change made by hand.
    var values: [Float] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func read() -> [Float]? { values }

    func write(_ values: [Float]) -> Bool {
        lock.withLock {
            stored[0] = values[0]
            if fail { fail = false; return false }
            stored = values.map { ($0 * 1_000).rounded() / 1_000 }
            return true
        }
    }
}

struct RecordingEnvironmentDuckingTests {
    private func ramp(_ values: [Float]) -> DuckingRamp<FakeOutput> { DuckingRamp(FakeOutput(values))! }
    private func close(_ a: [Float], _ b: [Float]) -> Bool { OutputDucking.close(a, b) }

    @Test func `ducking preserves balance silence and restores`() {
        let lowerMidpoint = OutputDucking.lower / 2, restoreMidpoint = OutputDucking.restore / 2
        for original: [Float] in [[0.3, 0.8], [0.0, 0.8], [0.5]] {
            for factor: Float in [0.0, 0.2, 1.0] {
                let midpoint = original.map { $0 * (1 + factor) / 2 }
                var r = ramp(original)
                r.retarget(factor)
                r.tick(lowerMidpoint)
                #expect(close(r.output.values, midpoint))
                r.tick(OutputDucking.lower)
                r.retarget(nil)
                r.tick(restoreMidpoint)
                #expect(close(r.output.values, midpoint))
                r.tick(OutputDucking.restore)
                #expect(close(r.output.values, original))
                #expect(r.finished)
            }
        }
    }

    @Test func `lowering finishes at its own duration while restoring is still ramping`() {
        let elapsed = OutputDucking.lower
        var lowered = ramp([0.3, 0.8])
        lowered.retarget(0.2)
        lowered.tick(elapsed)
        #expect(close(lowered.output.values, [0.06, 0.16]))
        #expect(lowered.settled)

        var restoring = ramp([0.3, 0.8])
        restoring.retarget(0.2)
        restoring.tick(elapsed)
        restoring.retarget(nil)
        restoring.tick(elapsed)
        #expect(!close(restoring.output.values, [0.3, 0.8]))
        #expect(restoring.output.values[0] < (0.06 + 0.3) / 2)
    }

    @Test func `ducking respects manual changes and restores interrupted ramps`() {
        var r = ramp([0.3, 0.8])
        r.retarget(0.2)
        r.tick(OutputDucking.lower)
        r.output.values = [0.5, 0.5]
        r.retarget(nil)
        r.tick(OutputDucking.restore)
        #expect(r.output.values == [0.5, 0.5])

        r = ramp([0.3, 0.8])
        r.retarget(0.0)
        r.tick(OutputDucking.lower / 2)
        r.retarget(nil)
        r.tick(OutputDucking.restore)
        #expect(close(r.output.values, [0.3, 0.8]))
    }

    @Test func `ducking rolls back every channel on partial failure`() {
        var r = ramp([0.3, 0.8])
        r.output.fail = true
        r.retarget(0.2)
        r.tick(OutputDucking.lower / 2)
        #expect(r.finished)
        #expect(close(r.output.values, [0.3, 0.8]))
    }

    /// Not Hex's: the guard on its own thread, in real time, lowers within its 120 ms and eases back on restore.
    @Test func `the guard lowers the output and restores it`() {
        let output = FakeOutput([0.4, 0.6])
        let held = OutputDuckingGuard.start(factor: 0.2) { output }
        Thread.sleep(forTimeInterval: OutputDucking.lower + 0.15)
        #expect(close(output.values, [0.08, 0.12]))
        held.restore()
        #expect(close(output.values, [0.4, 0.6]))
    }

    @Test func `the guard leaves a volume changed by hand while lowered`() {
        let output = FakeOutput([0.4, 0.6])
        let held = OutputDuckingGuard.start(factor: 0.2) { output }
        Thread.sleep(forTimeInterval: OutputDucking.lower + 0.15)
        output.values = [0.7, 0.7]
        held.restore()
        #expect(output.values == [0.7, 0.7])
    }
}
