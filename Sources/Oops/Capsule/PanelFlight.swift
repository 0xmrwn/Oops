import AppKit
import SwiftUI

/// The drop's panel carried to a new spot on one spring, stepped with the display: AppKit animates a window's frame
/// only on timing curves, and the drop inside moves across the panel on this same spring (`animation`), so the two
/// add up to one flight. A new target mid-flight bends the flight toward it, keeping its speed.
@MainActor final class PanelFlight {
    /// About half a second, with a little bounce as it lands.
    static let spring = Spring(duration: 0.5, bounce: 0.15)
    static let animation = Animation.spring(duration: 0.5, bounce: 0.15)
    var target: CGPoint
    /// The panel is there and still: the flight is over.
    var landed: () -> Void = {}
    private var x: Double, y: Double, vx = 0.0, vy = 0.0
    private var last = CACurrentMediaTime()
    private var timer: Timer?
    private let move: (CGPoint) -> Void

    init(from origin: CGPoint, move: @escaping (CGPoint) -> Void) {
        x = origin.x; y = origin.y; target = origin; self.move = move
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    isolated deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    private func step() {
        let now = CACurrentMediaTime()
        // A stall (a busy main thread) resumes where it was rather than leaping.
        let dt = min(now - last, 1.0 / 30)
        last = now
        Self.spring.update(value: &x, velocity: &vx, target: Double(target.x), deltaTime: dt)
        Self.spring.update(value: &y, velocity: &vy, target: Double(target.y), deltaTime: dt)
        if abs(x - target.x) < 0.5, abs(y - target.y) < 0.5, abs(vx) < 4, abs(vy) < 4 {
            move(target)
            stop()
            return landed()
        }
        move(CGPoint(x: x, y: y))
    }
}
