import Foundation
@testable import Oops
import Testing

@MainActor struct DropMotionTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private let toward = CGSize(width: -0.8, height: 0.45)

    /// Steps at 60 fps from `from` to `to` seconds into the run, with progress reported at `signs` seconds.
    private func run(_ motion: DropMotion, from: Double = 0, to: Double, signs: [Double] = [], counted: inout Int, last: inout Date?) {
        var t = from
        while t < to {
            t = min(to, t + 1.0 / 60)
            for sign in signs where sign > t - 1.0 / 60 && sign <= t { counted += 1; last = start.addingTimeInterval(sign) }
            motion.advance(to: start.addingTimeInterval(t), start: start, activities: counted, lastActivity: last, toward: toward)
        }
    }

    @Test func `a drop that reports no progress keeps fix's steady lap and reading eyes`() {
        let motion = DropMotion()
        var counted = 0, last: Date?
        run(motion, to: 12, counted: &counted, last: &last)
        #expect(abs(motion.angle - DropMotion.pace * 12) < 1e-6)
        #expect(motion.brightness(dark: true) == 0.75)
        #expect(motion.pose == nil, "the drop's own reading pose, as before")
    }

    @Test func `progress quickens and brightens the light, never past two laps a second`() {
        let motion = DropMotion()
        var counted = 0, last: Date?
        run(motion, to: 1, counted: &counted, last: &last)
        let before = motion.angle
        // A burst of steps: the light speeds up as far as its cap allows.
        run(motion, from: 1, to: 1.5, signs: [1.01, 1.02, 1.03, 1.04, 1.05], counted: &counted, last: &last)
        let lap = motion.angle - before
        #expect(lap > DropMotion.pace * 0.5 * 1.5)
        #expect(lap <= DropMotion.topPace * 0.5 + 1e-9)
        #expect(motion.brightness(dark: true) > 0.75)
        #expect(motion.pose != nil, "the eyes follow the run's progress once it reports any")
    }

    @Test func `after five quiet seconds the light calms and the eyes look around`() {
        let motion = DropMotion()
        var counted = 0, last: Date?
        run(motion, to: 12, signs: [0.5], counted: &counted, last: &last)
        let before = motion.angle
        run(motion, from: 12, to: 13, counted: &counted, last: &last)
        #expect(abs(motion.angle - before - DropMotion.quietPace) < 0.05)
        #expect(abs(motion.brightness(dark: true) - 0.5) < 0.01)
        let look = motion.pose?.look ?? .zero
        #expect(abs(look.width) > 0.8 || abs(look.height) > 0.8, "glancing left, right or up, not reading")

        // Progress again: back to reading pace.
        run(motion, from: 13, to: 14, signs: [13.1], counted: &counted, last: &last)
        let resumed = motion.angle
        run(motion, from: 14, to: 15, counted: &counted, last: &last)
        #expect(motion.angle - resumed > DropMotion.pace * 0.9)
    }

    @Test func `a new working phase starts from rest`() {
        let motion = DropMotion()
        var counted = 0, last: Date?
        run(motion, to: 3, signs: [1], counted: &counted, last: &last)
        let later = start.addingTimeInterval(60)
        motion.advance(to: later.addingTimeInterval(1), start: later, activities: counted, lastActivity: nil, toward: toward)
        #expect(abs(motion.angle - DropMotion.pace) < 1e-9)
        #expect(motion.pose == nil)
    }
}
