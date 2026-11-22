import Foundation

/// A damped spring stepped by hand, so every frame hands the glass a real model value and slow motion is one multiplier.
public struct WheelSpring: Equatable, Sendable {
    public var x: Double, v: Double, target: Double

    public init(_ x: Double = 0) {
        self.x = x
        v = 0
        target = x
    }

    /// `response` is the period in seconds; the integration is sub-stepped so a long frame behaves like short ones.
    public mutating func step(_ dt: Double, _ response: Double, _ damping: Double) {
        let w = 2 * Double.pi / max(response, 0.05)
        var left = dt
        while left > 0 {
            let h = min(left, 1.0 / 480)
            v += (-w * w * (x - target) - 2 * damping * w * v) * h
            x += v * h
            left -= h
        }
    }

    public var resting: Bool { abs(x - target) < 0.0008 && abs(v) < 0.002 }
}
