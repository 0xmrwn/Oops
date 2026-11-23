import SwiftUI

/// The working drop's pace, stepped by the drop's frames: each sign of progress (`CapsuleModel.activity()`) quickens
/// and brightens the travelling light, and after a quiet spell the light slows and dims and the eyes look around
/// instead of reading. A drop that never reports progress, Fix's, keeps the steady lap and the reading eyes.
@MainActor final class DropMotion {
    /// The light's angle in radians.
    private(set) var angle = 0.0
    /// The eyes once the run has reported progress; nil before, for the drop's own reading pose.
    private(set) var pose: (look: CGSize, lid: Double)?
    private var start: Date?, last = Date.distantPast, seen = 0, run: Int?
    /// Extra speed (radians a second) and brightness, each sign's share halving every 1.5 s.
    private var boost = 0.0, flare = 0.0
    /// 0 busy … 1 quiet, eased so the light settles rather than switches.
    private var calm = 0.0, calmVelocity = 0.0, calmSince: Date?
    private var look = CGSize.zero, lookVelocity = CGSize.zero

    /// Fix's lap, about one every 1.8 s; a quiet run's, one every 4 s; and the fastest any burst of progress drives it.
    nonisolated static let pace = 3.5, quietPace = 2 * Double.pi / 4, topPace = 2 * 2 * Double.pi
    /// How long without progress makes a run quiet.
    nonisolated static let quietAfter = 5.0
    /// Quiet eyes glance left, right and up, a blink between.
    private static let glances = [CGSize(width: -0.9, height: 0), CGSize(width: 0.9, height: 0), CGSize(width: 0, height: -0.9)]

    /// Steps to `date`, from the working phase's `start`. Idempotent for a frame: the light and the eyes both call it.
    /// A new `run` (`CapsuleModel.clearRun()`) forgets the last one's progress; the light carries on where it is.
    func advance(to date: Date, start: Date, run: Int, activities: Int, lastActivity: Date?, toward: CGSize) {
        if start != self.start { self.start = start; last = start; angle = 0; self.run = nil }
        if run != self.run { self.run = run; seen = activities; boost = 0; flare = 0; calm = 0; calmVelocity = 0; calmSince = nil; pose = nil }
        let dt = date.timeIntervalSince(last)
        guard dt > 0 else { return }
        last = date
        for _ in seen..<max(seen, activities) { boost = min(boost + 0.8 * 2 * .pi, Self.topPace); flare = 1 }
        seen = activities
        let decay = pow(0.5, dt / 1.5)
        boost *= decay; flare *= decay
        let quiet = lastActivity.map { date.timeIntervalSince($0) >= Self.quietAfter } ?? false
        // A long gap between frames (the drop was off screen) settles at once rather than overshooting.
        let step = min(dt, 0.1)
        Spring(duration: quiet ? 1.1 : 0.35, bounce: 0).update(value: &calm, velocity: &calmVelocity, target: quiet ? 1 : 0, deltaTime: step)
        calmSince = quiet ? calmSince ?? date : nil
        angle += min(Self.pace + (Self.quietPace - Self.pace) * calm + boost, Self.topPace) * dt
        guard lastActivity != nil else { return }
        let (target, lid) = eyes(date.timeIntervalSince(start), at: date, toward: toward)
        if pose == nil { look = target; lookVelocity = .zero }
        let spring = Spring(duration: 0.24, bounce: 0.05)
        spring.update(value: &look.width, velocity: &lookVelocity.width, target: target.width, deltaTime: step)
        spring.update(value: &look.height, velocity: &lookVelocity.height, target: target.height, deltaTime: step)
        pose = (look, lid)
    }

    /// Where the eyes head, `t` seconds into the working phase: reading, with a blink every few lines, or glancing round.
    private func eyes(_ t: Double, at date: Date, toward: CGSize) -> (CGSize, Double) {
        guard let calmSince else { return DashEyes.readingPose(t.truncatingRemainder(dividingBy: 5.4), toward: toward) }
        let u = (date.timeIntervalSince(calmSince) - 0.6).truncatingRemainder(dividingBy: 3.6)
        guard u >= 0 else { return (toward, 0.4) }
        let since = u.truncatingRemainder(dividingBy: 1.2)
        return (Self.glances[Int(u / 1.2) % 3], 0.12 + 0.88 * max(0, 1 - abs(since - 0.05) / 0.09))
    }

    /// The arc's peak opacity: the drop's usual light, dimmer while quiet and brighter just after progress.
    func brightness(dark: Bool) -> Double {
        let base = dark ? 0.75 : 0.95
        return min(1, base + (0.5 - base) * calm + 0.25 * flare)
    }
}

/// A working drop's step changing, on one linear clock: the old label fades and lifts away in the first half, and the
/// new one rises `rise` points into place, easing out, from a third of the way in, so the two never ghost together.
struct StepChange: ViewModifier, Animatable {
    /// 0 out of sight … 1 in place.
    var progress: Double
    let arriving: Bool, rise: CGFloat
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static func transition(rise: CGFloat) -> AnyTransition {
        .asymmetric(insertion: .modifier(active: Self(progress: 0, arriving: true, rise: rise), identity: Self(progress: 1, arriving: true, rise: rise)),
                    removal: .modifier(active: Self(progress: 0, arriving: false, rise: rise), identity: Self(progress: 1, arriving: false, rise: rise)))
    }

    func body(content: Content) -> some View {
        let gone = arriving ? 0 : min(1, (1 - progress) * 2), shown = arriving ? 1 - pow(1 - min(max((progress - 0.3) / 0.7, 0), 1), 2) : 1 - gone
        content.opacity(shown).offset(y: arriving ? rise * (1 - shown) : -rise * 0.75 * gone)
    }
}
