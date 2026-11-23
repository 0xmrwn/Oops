import AppKit
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
            motion.advance(to: start.addingTimeInterval(t), start: start, run: 0, activities: counted, lastActivity: last, toward: toward)
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
        motion.advance(to: later.addingTimeInterval(1), start: later, run: 0, activities: counted, lastActivity: nil, toward: toward)
        #expect(abs(motion.angle - DropMotion.pace) < 1e-9)
        #expect(motion.pose == nil)
    }

    @Test func `a run replaced while working drops its progress but not the light's place`() {
        let motion = DropMotion()
        var counted = 0, last: Date?
        run(motion, to: 12, signs: [0.5], counted: &counted, last: &last)
        let angle = motion.angle
        // Fix takes the drop over without it leaving `.working`: steady pace, its own reading eyes, no jump.
        let next = start.addingTimeInterval(12 + 1.0 / 60)
        motion.advance(to: next, start: start, run: 1, activities: counted, lastActivity: nil, toward: toward)
        #expect(motion.pose == nil)
        #expect(abs(motion.angle - angle - DropMotion.pace / 60) < 1e-6)
        #expect(motion.brightness(dark: true) == 0.75)
    }
}

@MainActor struct DropLabelTests {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)

    @Test func `a label that fits is left whole`() {
        let parts = ["Rewrite", "1.2s"]
        #expect(DropLabel.fitted(parts, room: 500, font: font, divider: 15) == parts)
    }

    @Test func `a long step loses words from its end and keeps the timing`() {
        let parts = ["Searching “how to write a cover letter that stands out”", "0:12"]
        let room = DropLabel.width(["Searching “how to write a…", "0:12"], font: font, divider: 15) + 2
        let fitted = DropLabel.fitted(parts, room: room, font: font, divider: 15)
        #expect(fitted == ["Searching “how to write a…", "0:12"])
        #expect(DropLabel.width(fitted, font: font, divider: 15) <= room)
    }

    @Test func `one word too wide is cut by its letters`() {
        let fitted = DropLabel.fitted(["developer.mozilla.org"], room: 80, font: font, divider: 15)
        #expect(fitted.first?.hasPrefix("dev") == true && fitted.first?.hasSuffix("…") == true)
        #expect(DropLabel.width(fitted, font: font, divider: 15) <= 80)
    }
}
