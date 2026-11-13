import Foundation

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

// MARK: - Analytical Spring (`src/spring.rs`)

struct DotSpringSpec: Equatable, Sendable {
    var duration: Float
    var bounce: Float

    static let reducedFade = DotSpringSpec(duration: 0.18, bounce: 0.0)

    var omega: Float {
        (2.0 * .pi) / max(duration, 0.01)
    }

    var zeta: Float {
        if bounce >= 0 {
            return max(1.0 - bounce, 0.0)
        }
        return 1.0 / max(1.0 + bounce, 0.01)
    }
}

struct DotSpring: Equatable, Sendable {
    private static let criticalTolerance: Float = 1e-4

    var x: Float
    var v: Float = 0
    var target: Float

    init(at value: Float) {
        self.x = value
        self.v = 0
        self.target = value
    }

    mutating func jump(_ value: Float) {
        x = value
        v = 0
        target = value
    }

    mutating func step(to newTarget: Float, spec: DotSpringSpec, dt: Float) {
        target = newTarget
        guard dt > 0, dt.isFinite else { return }

        let omega = spec.omega
        let zeta = spec.zeta
        let x0 = x - target
        let v0 = v

        if zeta < 1.0 - Self.criticalTolerance {
            let decay = zeta * omega
            let omegaD = omega * sqrt(1.0 - zeta * zeta)
            let expTerm = exp(-decay * dt)
            let s = sin(omegaD * dt)
            let c = cos(omegaD * dt)
            let sinOverD = s / omegaD
            x = target + expTerm * (x0 * (c + decay * sinOverD) + v0 * sinOverD)
            v = expTerm * (-x0 * omega * omega * sinOverD + v0 * (c - decay * sinOverD))
        } else if zeta > 1.0 + Self.criticalTolerance {
            let root = sqrt(zeta * zeta - 1.0)
            let rootSum = zeta + root
            let slowRoot = -omega / rootSum
            let fastRoot = -omega * rootSum
            let denom = slowRoot - fastRoot
            let slowExp = exp(slowRoot * dt)
            let fastExp = exp(fastRoot * dt)
            let p00 = (-fastRoot * slowExp + slowRoot * fastExp) / denom
            let p01 = (slowExp - fastExp) / denom
            let p10 = slowRoot * fastRoot * (fastExp - slowExp) / denom
            let p11 = (slowRoot * slowExp - fastRoot * fastExp) / denom
            x = target + p00 * x0 + p01 * v0
            v = p10 * x0 + p11 * v0
        } else {
            let expTerm = exp(-omega * dt)
            let c = v0 + omega * x0
            x = target + (x0 + c * dt) * expTerm
            v = (v0 - omega * c * dt) * expTerm
        }
    }
}

// MARK: - Auto Level (`src/dot_scope.rs`)

struct DotScopeAutoLevel: Equatable, Sendable {
    private static let minSpan: Float = 16.0
    private static let range: Float = 24.0
    private static let roomMargin: Float = 5.0
    private static let attack: Float = 0.04
    private static let roomFall: Float = 0.30
    private static let roomRise: Float = 6.0

    var peak: Float = -30.0
    var room: Float = -55.0

    mutating func step(loudness: Float, dt: Float, release: Float, noiseFloor: Float) -> Float {
        let db = max(loudness, -120.0)
        func follow(_ value: inout Float, _ target: Float, _ time: Float) {
            value += (target - value) * (1.0 - exp(-dt / max(time, 1e-3)))
        }
        follow(&room, db, db < room ? Self.roomFall : Self.roomRise)
        let lowest = max(room, noiseFloor) + Self.minSpan
        if db > peak {
            follow(&peak, db, Self.attack)
        } else {
            follow(&peak, lowest, release)
        }
        peak = max(peak, lowest)
        let low = max(max(room, noiseFloor) + Self.roomMargin, peak - Self.range)
        return min(1.0, max(0.0, (db - low) / max(peak - low, 1.0)))
    }
}
