import Foundation

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

// MARK: - Voices and traces of the 240 Hz braided oscilloscope (`src/dot_scope/scope.rs`)

extension DotScopeSimulation {
    struct Voice {
        var level: Float = 0
        var reservoir: Float = 0
        var energy: Float = 0
        var kick: Float = 0
        var kickVelocity: Float = 0
        var band: Float = 0

        mutating func step(raw: Float, h: Float) {
            let previous = level
            let tLevel: Float = raw > level ? 0.035 : 0.095
            level += (raw - level) * (1.0 - exp(-h / tLevel))
            let rise = max(0.0, (level - previous) / h)
            reservoir += (1.75 * level * level - reservoir / 1.8) * h
            energy = 1.0 - exp(-reservoir * 1.45)
            let w: Float = 2.0 * .pi * 1.3
            let z: Float = 0.22
            kickVelocity += (-w * w * kick - 2.0 * z * w * kickVelocity + 15.0 * rise + 2.2 * level) * h
            kick += kickVelocity * h
            let tBand: Float = raw > band ? 0.025 : 0.14
            band += (raw - band) * (1.0 - exp(-h / tBand))
        }
    }

    struct Trace {
        var envelope: Float = 0
        var amplitude: Float = 0
        var amplitudeVelocity: Float = 0
        var glowFast: Float = 0
        var glowSpring: Float = 0
        var glowSpringVelocity: Float = 0
        var glowSlow: Float = 0
        var glow: Float = 0
        var phases: SIMD4<Float>
        var history: [Float]
        var head: Int = 0

        init(phases: SIMD4<Float>) {
            self.phases = phases
            self.history = Array(repeating: 0, count: DotScopeSimulation.historyCount * 5)
        }

        mutating func tick(voice: Voice, live: Float, speed: Float, tuning: DotScopeTuning, h: Float) {
            func follow(_ value: inout Float, _ target: Float, _ rise: Float, _ fall: Float) {
                let t = target > value ? rise : fall
                value += (target - value) * (1.0 - exp(-h / max(t, 1e-4)))
            }
            follow(&envelope, voice.level, 0.022, tuning.release)
            let w = DotScopeSimulation.tau * tuning.response
            let z: Float = 0.52
            amplitudeVelocity += (-w * w * (amplitude - envelope) - 2.0 * z * w * amplitudeVelocity) * h
            amplitude += amplitudeVelocity * h

            follow(&glowFast, voice.level, 0.045, 0.13)
            let gw = DotScopeSimulation.tau * 3.6
            let gz: Float = 0.50
            glowSpringVelocity += (-gw * gw * (glowSpring - glowFast) - 2.0 * gz * gw * glowSpringVelocity) * h
            glowSpring += glowSpringVelocity * h
            follow(&glowSlow, voice.level, 0.15, 0.70)

            let swell = 0.8 * max(0.0, glowSpring - 0.25) + 0.04 * max(-0.5, voice.kick)
            glow = min(1.15, max(0.0, swell) + 0.42 * glowSlow + 0.20 * voice.energy) * live

            let go = 0.6 + 1.1 * min(1.0, envelope * 1.6)
            let s = DotScopeSimulation.speeds
            let stepFactors = SIMD4<Float>(s.0, s.1, s.2, s.3) * (h * DotScopeSimulation.tau * go * speed)
            phases += stepFactors
            for lane in 0..<4 where phases[lane] >= DotScopeSimulation.tau {
                phases[lane] = phases[lane].truncatingRemainder(dividingBy: DotScopeSimulation.tau)
            }

            let emphasis = 0.35 + 0.65 * min(2.0, voice.band / (voice.band + 0.06))
            let offset = head * 5
            let amp = max(0.0, amplitude) * live
            let b = DotScopeSimulation.baseWeights
            history[offset] = amp
            history[offset + 1] = amp * b.0 * emphasis
            history[offset + 2] = amp * b.1 * emphasis
            history[offset + 3] = amp * b.2 * emphasis
            history[offset + 4] = amp * b.3 * emphasis
            head = (head + 1) % DotScopeSimulation.historyCount
        }

        func past(delay: Float, channel: Int) -> Float {
            let count = DotScopeSimulation.historyCount
            let d = min(delay / DotScopeSimulation.stepDt, Float(count - 2))
            let i = Int(floor(d))
            let k = d - Float(i)
            let a = (head + 2 * count - 1 - i) % count
            let b = (a + count - 1) % count
            return history[a * 5 + channel] * (1.0 - k) + history[b * 5 + channel] * k
        }
    }
}
