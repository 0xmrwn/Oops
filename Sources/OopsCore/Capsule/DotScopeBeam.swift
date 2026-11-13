import Foundation

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

// MARK: - The beam: traces to lit dots (`src/dot_scope/scope.rs`)

extension DotScopeSimulation {
    @inline(__always)
    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1.0, max(0.0, (x - a) / (b - a)))
        return t * t * (3.0 - 2.0 * t)
    }

    @inline(__always)
    private static func bump(_ d: Float, _ w: Float) -> Float {
        let r = d / w
        return exp(-r * r)
    }

    @inline(__always)
    private static func hermite(start: Float, speed: Float, end: Float, t rawT: Float) -> Float {
        let t = min(1.0, max(0.0, rawT))
        let t2 = t * t
        let t3 = t2 * t
        return (2.0 * t3 - 3.0 * t2 + 1.0) * start
            + (t3 - 2.0 * t2 + t) * wipeDuration * speed
            + (3.0 * t2 - 2.0 * t3) * end
    }

    @inline(__always)
    private static func remEuclid(_ a: Float, _ b: Float) -> Float {
        let r = a.truncatingRemainder(dividingBy: b)
        return r < 0 ? r + b : r
    }

    private func flowLight(x: Float) -> Float {
        let spacing = flowSpacing
        let d = Self.remEuclid(x - flowOffset + spacing * 0.5, spacing) - spacing * 0.5
        return Self.bump(d, 8.5)
    }

    func beam(hb: Float) {
        let cols = columns
        let rws = rows
        let sub = Self.samplesPerColumn
        let sampleCount = (cols - 1) * sub + 1
        let pitch = tuning.spacing
        let width = max(widthSpring.x, tuning.height)
        let halfWidth = width * 0.5
        let activeCenter = tuning.fitsBounds ? (leadingInsetSpring.x - trailingInsetSpring.x) * 0.5 : 0.0
        let e = elapsed

        let scanHelix: Float
        let scanDecay: Float
        let scanTail: Float
        let scanGrid: Float

        enum Mode {
            case still
            case enter(reach: Float, head: Float, unfold: Float)
            case work(head: Float, swell: Float)
            case clear(front: Float, head: Float, glow: Float)
        }
        let mode: Mode

        if stage == .failed || stage == .idle || reduceMotion {
            scanHelix = stage == .idle ? 0.55 : 1.0
            scanDecay = 1.0; scanTail = 1.0; scanGrid = 1.0
            mode = .still
        } else {
            switch stage {
            case .idle:
                scanHelix = 0.55; scanDecay = 1.0; scanTail = 1.0; scanGrid = 1.0
                mode = .still

            case .recording:
                scanHelix = 1.0; scanDecay = 1.0; scanTail = 1.0
                if enterFromHidden {
                    scanGrid = min(1.0, e / 0.30)
                    let p = min(1.0, max(0.0, e / Self.enterDuration))
                    let passPos = 0.5 - 0.5 * cos(.pi * p)
                    let reach = (halfWidth + 14.0) * passPos
                    let head = 2.8 * (1.0 - Self.smoothstep(0.08, Self.enterDuration, e))
                    let unfold = Self.smoothstep(0.0, 0.10, e)
                    mode = .enter(reach: reach, head: head, unfold: unfold)
                } else {
                    scanGrid = 1.0
                    mode = .still
                }

            case .processing:
                let enter = Self.smoothstep(0.0, 0.35, e)
                scanHelix = 1.0 + (Self.workHelix - 1.0) * enter
                scanDecay = 1.0; scanTail = 1.0; scanGrid = 1.0
                let head = 2.5 * Self.smoothstep(0.05, 0.30, e) * tuning.shimmer
                mode = .work(head: head, swell: 0.9 * enter)

            case .done:
                let target = halfWidth + 8.0
                let front = Self.hermite(start: 0.0, speed: speedAtDone, end: target, t: e / Self.wipeDuration)
                scanHelix = Self.workHelix
                scanDecay = 1.0 - 0.6 * Self.smoothstep(0.0, 0.12, e)
                scanTail = 1.0 - Self.smoothstep(0.0, 0.15, e)
                scanGrid = 1.0 - Self.smoothstep(0.20, 0.40, e)
                let head = 2.8 * Self.smoothstep(0.0, 0.04, e) * (1.0 - Self.smoothstep(0.22, 0.32, e))
                let glow = 2.5 * tuning.shimmer * (1.0 - Self.smoothstep(0.0, 0.18, e))
                mode = .clear(front: front, head: head, glow: glow)

            case .failed:
                scanHelix = 1.0; scanDecay = 1.0; scanTail = 1.0; scanGrid = 1.0
                mode = .still
            }
        }

        grid = scanGrid
        let mid = Float(rws - 1) * 0.5
        let half = mid - 0.55
        let breath: Float = reduceMotion ? 0.5 : (0.5 + 0.5 * sin(time * Self.tau / Self.breathPeriod))
        let idleScale: Float = stage == .idle ? 0.48 : 1.0
        let rest = (0.55 + 0.35 * breath) * (0.35 + 0.65 * live) * scanHelix * idleScale
        let sf = Self.spatialFreqs
        let reachAttenuation: Float = tuning.fitsBounds ? 0.48 : 0.80
        let reachInner: Float = tuning.fitsBounds ? 26.0 : 14.0

        func scanAt(_ x: Float) -> (Float, Float, Float) {
            switch mode {
            case .still:
                return (1.0, 1.0, 0.0)
            case .enter(let reach, let head, let unfold):
                let d = abs(x)
                let drawn = unfold * (1.0 - Self.smoothstep(max(0.0, reach - 14.0), max(0.001, reach), d))
                let amp = drawn * (1.0 - Self.smoothstep(max(0.0, reach - 22.0), max(0.001, reach - 3.0), d))
                let beamLight = head * Self.bump(d - reach, 6.0)
                let swell = 1.8 * unfold * (head / 2.8) * Self.bump(d - max(0.0, reach - 14.0), 14.0)
                return (amp, amp + beamLight, swell)
            case .work(let head, let swell):
                let light = flowLight(x: x)
                return (1.0, 1.0 + head * light, swell * light)
            case .clear(let front, let head, let glow):
                let d = abs(x)
                let keep = Self.smoothstep(front - 12.0, front - 2.0, d)
                let light = flowLight(x: x)
                return (
                    keep,
                    keep * (1.0 + glow * light) + head * Self.bump(d - front, 6.0),
                    keep * 0.9 * light
                )
            }
        }

        func fillSamples(trace: Trace, sign: Float, ys: inout [Float], brightness: inout [Float]) {
            let p = trace.phases
            for s in 0..<sampleCount {
                let sampleX = (Float(s) / Float(sub) - Float(cols - 1) * 0.5) * pitch
                let x = sampleX - activeCenter
                if abs(x) > halfWidth {
                    ys[s] = mid
                    brightness[s] = 0
                    continue
                }
                let (amp, bright, swell) = scanAt(x)
                let own = abs(x)
                let xn = (x + halfWidth) / width
                let ends = min(
                    Self.smoothstep(-halfWidth + 2.5, -halfWidth + 18.0, x),
                    Self.smoothstep(-halfWidth + 2.5, -halfWidth + 18.0, -x)
                )
                let reach = 1.0 - reachAttenuation * Self.smoothstep(reachInner, max(reachInner + 1.0, halfWidth), own)
                let delay = own / tuning.historySpeed
                let a = trace.past(delay: delay, channel: 0)
                var spread: Float = 0
                spread += trace.past(delay: delay, channel: 1) * sin(Self.tau * sf.0 * xn - p[0])
                spread += trace.past(delay: delay, channel: 2) * sin(Self.tau * sf.1 * xn - p[1])
                spread += trace.past(delay: delay, channel: 3) * sin(Self.tau * sf.2 * xn - p[2])
                spread += trace.past(delay: delay, channel: 4) * sin(Self.tau * sf.3 * xn - p[3])

                let helix = (rest + swell + half * 0.55 * a * reach)
                    * sin(Self.tau * tuning.helixCycles * xn - carrier)
                let y = half * tanh((helix + half * 0.72 * spread * reach) / max(half, 0.01)) * ends * amp
                ys[s] = mid - sign * y
                let idleDim: Float = stage == .idle ? 0.58 : 1.0
                let spatial = (0.3 + 0.7 * min(1.0, a * 1.8)) * (0.45 + 0.55 * ends) * idleDim
                brightness[s] = spatial * amp + 0.36 * max(0.0, bright - amp)
            }
            for s in 0..<sampleCount {
                let nextIdx = min(sampleCount - 1, s + 1)
                let prevIdx = max(0, s - 1)
                let slope = (ys[nextIdx] - ys[prevIdx]) * Float(sub) * 0.5
                brightness[s] *= 0.45 + 0.55 / sqrt(1.0 + 0.22 * slope * slope)
            }
        }

        fillSamples(trace: traces.0, sign: 1.0, ys: &ys0, brightness: &bright0)
        fillSamples(trace: traces.1, sign: -1.0, ys: &ys1, brightness: &bright1)

        let headKeep = exp(-hb / max(1e-4, Self.phosphorHead * scanDecay))
        let tailKeep = exp(-hb / max(1e-4, tuning.phosphor * scanDecay))
        let dx = 1.0 / Float(sub)
        let dx2 = dx * dx

        for i in 0..<cols {
            let s0 = max(0, i - 3) * sub
            let s1 = min(sampleCount - 1, (i + 3) * sub)
            let fi = Float(i)
            for j in 0..<rws {
                let fj = Float(j)
                let n = j * cols + i

                func traceLight(
                    ys: [Float],
                    bright: [Float],
                    headArr: inout [Float],
                    tailArr: inout [Float]
                ) -> (instant: Float, light: Float) {
                    var best = Float.greatestFiniteMagnitude
                    var nearest = i * sub
                    for s in s0..<s1 {
                        let ay = ys[s]
                        let dy = ys[s + 1] - ay
                        let px = fi - Float(s) * dx
                        let py = fj - ay
                        let t = min(1.0, max(0.0, (px * dx + py * dy) / (dx2 + dy * dy)))
                        let ex = px - t * dx
                        let ey = py - t * dy
                        let d2 = ex * ex + ey * ey
                        if d2 < best {
                            best = d2
                            nearest = s
                        }
                    }
                    let b = bright[nearest]
                    let onBeam = exp(-best / 0.25)
                    let instant = min(1.2, onBeam + 0.5 * exp(-sqrt(best) / 0.8)) * b
                    let core = onBeam * b
                    let nextHead = max(headArr[n] * headKeep, core)
                    let nextTail = max(tailArr[n] * tailKeep, core)
                    headArr[n] = nextHead
                    tailArr[n] = nextTail
                    let light = max(instant, max(nextHead, 0.55 * scanTail * nextTail))
                    return (instant, light)
                }

                let t0 = traceLight(ys: ys0, bright: bright0, headArr: &head0, tailArr: &tail0)
                let t1 = traceLight(ys: ys1, bright: bright1, headArr: &head1, tailArr: &tail1)
                let nowSum = t0.instant + t1.instant
                let totalSum = t0.light + t1.light
                let power = min(1.0, max(0.0, 1.0 - (1.0 - min(1.0, t0.light)) * (1.0 - min(1.0, t1.light))))
                let fresh = min(1.0, max(0.0, nowSum / max(totalSum, 1e-4)))

                dots[n] = SIMD2<Float>(power, fresh)
                packedDots[n] = SIMD2<UInt16>(
                    UInt16((power * 65535.0).rounded()),
                    UInt16((fresh * 65535.0).rounded())
                )
            }
        }
    }
}
