import Foundation
import Testing
@testable import OopsCore

/// The cue that teaches the typed centre: when it shows, its timeline from the shortcut, and what ends it.
struct WheelCueTests {
    private let frame = 1.0 / 120
    /// When the window came up after the shortcut.
    private let placed = 0.1

    private func teaching(reduceMotion: Bool = false) -> WheelMotion {
        var motion = WheelMotion(reduceMotion: reduceMotion)
        motion.open()
        motion.bloom(WheelFixtures.petals([.up, .right, .down, .left]))
        motion.teach(opened: placed)
        return motion
    }

    /// Steps until `time` after the shortcut.
    private func run(_ motion: inout WheelMotion, to time: Double) {
        while motion.clock + placed < time - 1e-9 { motion.step(frame) }
    }

    @Test func `it shows until an instruction is typed, or for five opens`() {
        #expect(WheelCue.shows(typed: false, opens: 0))
        #expect(WheelCue.shows(typed: false, opens: 4))
        #expect(!WheelCue.shows(typed: false, opens: 5))
        #expect(!WheelCue.shows(typed: true, opens: 0))
    }

    @Test func `the words come and go and the eyes glance once, timed from the shortcut`() {
        var motion = teaching()
        run(&motion, to: 0.34)
        #expect(motion.hint.target == 0 && motion.glance.target == 0)
        run(&motion, to: 0.36)
        #expect(motion.hint.target == 1 && motion.cueWords)
        run(&motion, to: 0.44)
        #expect(motion.glance.target == 0)
        run(&motion, to: 0.46)
        #expect(motion.glance.target == 1)
        run(&motion, to: 1.06)
        #expect(motion.glance.target == 1)
        run(&motion, to: 1.08)
        #expect(motion.glance.target == 0)
        run(&motion, to: 1.94)
        #expect(motion.hint.target == 1)
        run(&motion, to: 1.96)
        #expect(motion.hint.target == 0)
        run(&motion, to: 4)
        #expect(motion.resting)
    }

    @Test func `under Reduce Motion the glance holds for 0.9 s`() {
        var motion = teaching(reduceMotion: true)
        run(&motion, to: 1.34)
        #expect(motion.glance.target == 1)
        run(&motion, to: 1.36)
        #expect(motion.glance.target == 0)
    }

    @Test func `pointing clears it at once, and it doesn't come back`() {
        var motion = teaching()
        run(&motion, to: 0.6)
        motion.setLive(.right)
        #expect(motion.hint.target == 0 && motion.glance.target == 0)
        run(&motion, to: 0.7)
        motion.setLive(nil)
        run(&motion, to: 3)
        #expect(motion.hint.x < 0.01 && motion.glance.x < 0.01)
        #expect(motion.hint.target == 0 && motion.glance.target == 0)
    }

    @Test func `typing clears it at once`() {
        var motion = teaching()
        run(&motion, to: 0.6)
        motion.beginTyping()
        #expect(motion.hint.target == 0 && motion.glance.target == 0)
        run(&motion, to: 3)
        #expect(motion.hint.target == 0 && motion.glance.target == 0)
    }

    @Test func `an action's ring hint is not the cue`() {
        var motion = teaching()
        run(&motion, to: 0.6)
        motion.select(.right, symbol: "globe")
        motion.showHint()
        #expect(!motion.cueWords && motion.hint.target == 1)
        run(&motion, to: 3)
        #expect(motion.hint.target == 1 && motion.glance.target == 0)
    }

    @Test func `the field's words show only once the glass has reached them`() {
        var motion = WheelMotion()
        motion.open()
        for _ in 0 ..< 60 { motion.step(frame) }
        motion.beginTyping()
        #expect(motion.fieldReveal == 0)
        let start = WheelLayout.hub.x - WheelLayout.field / 2 + WheelLayout.fieldText
        var hidden = 0
        for _ in 0 ..< 120 {
            motion.step(frame)
            if motion.fieldReveal == 0 { hidden += 1 }
            if motion.fieldReveal > 0 { #expect(motion.centrePoint.x - motion.centreSize.width / 2 < start - 4, "words only inside the glass") }
        }
        // The glass takes more than 100 ms to reach the words' start, which they used to show at from the first key.
        #expect(hidden > 12)
        #expect(motion.fieldReveal == 1)
    }
}
