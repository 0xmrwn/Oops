import Foundation
import Testing
@testable import OopsCore

/// When the window can stop drawing: the motion at rest and nothing waiting on time.
struct WheelIdleTests {
    private let frame = 1.0 / 120

    private func steps(_ motion: inout WheelMotion, _ seconds: Double) {
        for _ in 0 ..< Int(seconds / frame) { motion.step(frame) }
    }

    @Test func `the motion comes to rest after the bloom and again after pointing`() {
        var motion = WheelMotion()
        motion.open()
        motion.bloom(WheelFixtures.petals([.up, .right, .down, .left]))
        #expect(!motion.resting, "launches are still due")
        steps(&motion, 2)
        #expect(motion.resting)
        motion.setLive(.right)
        #expect(!motion.resting)
        steps(&motion, 2)
        #expect(motion.resting)
        motion.showNames()
        #expect(!motion.resting, "names still have to come out")
        steps(&motion, 2)
        #expect(motion.resting)
    }

    @Test func `the linger is due until names show, then nothing is`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.nextDue == WheelTiming.linger)
        _ = wheel.advance(to: 0.71)
        #expect(wheel.named)
        #expect(wheel.nextDue == nil)
    }

    @Test func `pointing holds the linger back, a release is due after its grace`() {
        var wheel = WheelFixtures.opened()
        _ = wheel.press(.right, at: 0.3)
        #expect(wheel.nextDue == nil, "a held arrow waits on the person, not on time")
        _ = wheel.release(.right, at: 0.4)
        #expect(abs((wheel.nextDue ?? 0) - 0.45) < 1e-9)
    }

    @Test func `an early arrow is due at the flick's end, a ring at its bloom`() {
        var wheel = WheelFixtures.opened()
        _ = wheel.press(.down, at: 0.05)
        #expect(abs((wheel.nextDue ?? 0) - WheelTiming.flick) < 1e-9)

        var ring = WheelFixtures.opened()
        _ = WheelFixtures.tap(&ring, .right, at: 0.3)
        guard case .choices = ring.level else { Issue.record("expected the choice ring"); return }
        #expect(abs((ring.nextDue ?? 0) - (0.4 + WheelTiming.choicesDelay)) < 1e-9)
    }

    @Test func `a closed wheel waits on nothing`() {
        var wheel = WheelFixtures.opened()
        _ = wheel.close()
        #expect(wheel.nextDue == nil)
    }
}
