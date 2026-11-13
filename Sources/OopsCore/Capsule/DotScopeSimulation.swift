import Foundation

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.
// The simulation is split across three files: this one holds its state and stepping, `DotScopeTrace.swift`
// the per-voice filters and `DotScopeBeam.swift` the beam that turns the traces into lit dots.

// MARK: - 240 Hz Braided Oscilloscope Simulation (`src/dot_scope/scope.rs`)

package final class DotScopeSimulation: @unchecked Sendable {
    static let stepDt: Float = 1.0 / 240.0
    static let historyCount = 512
    static let samplesPerColumn = 3
    static let speeds: (Float, Float, Float, Float) = (0.8, 1.25, 1.85, 2.6)
    static let baseWeights: (Float, Float, Float, Float) = (0.55, 0.42, 0.30, 0.20)
    static let spatialFreqs: (Float, Float, Float, Float) = (1.4, 2.4, 3.8, 5.6)
    static let startWidth: Float = 30.0
    static let enterDuration: Float = 0.42
    static let wipeDuration: Float = 0.30
    static let phosphorHead: Float = 0.15
    static let breathPeriod: Float = 5.5
    static let hiddenScale: Float = 0.90
    static let hiddenSoftness: Float = 3.0
    static let workHelix: Float = 2.6
    static let flowSpacingFactor: Float = 0.70
    static let carrierRest: Float = 0.14
    static let idleLiveTarget: Float = 0.18
    static let tau: Float = 2.0 * .pi

    package internal(set) var tuning: DotScopeTuning
    package internal(set) var stage: DotScopeStage = .recording
    var elapsed: Float = 0
    var speedAtDone: Float = 0
    var doneFrom: Float = 0
    var flowOffset: Float = 0
    var flowTurn: Float = 0
    var auto = DotScopeAutoLevel()
    package internal(set) var level: Float = 0
    var voices = (Voice(), Voice())
    var traces = (
        Trace(phases: SIMD4<Float>(0.1, 1.7, 3.3, 4.6)),
        Trace(phases: SIMD4<Float>(2.4, 0.6, 5.1, 1.9))
    )
    var live: Float = 0
    var carrier: Float = 0
    var time: Float = 0
    var steps: UInt64 = 0
    var pending: Float = 0
    var reduceMotion = false

    package internal(set) var columns: Int = 0
    package internal(set) var rows: Int = 0
    var head0: [Float] = []
    var head1: [Float] = []
    var tail0: [Float] = []
    var tail1: [Float] = []
    var ys0: [Float] = []
    var ys1: [Float] = []
    var bright0: [Float] = []
    var bright1: [Float] = []
    package internal(set) var dots: [SIMD2<Float>] = []
    package internal(set) var packedDots: [SIMD2<UInt16>] = []

    var grid: Float = 0
    var widthSpring = DotSpring(at: startWidth)
    var leadingInsetSpring = DotSpring(at: 0.0)
    var trailingInsetSpring = DotSpring(at: 0.0)
    var opacitySpring = DotSpring(at: 0.0)
    var scaleSpring = DotSpring(at: hiddenScale)
    var softnessSpring = DotSpring(at: hiddenSoftness)
    var coolSpring = DotSpring(at: 0.0)
    var failSpring = DotSpring(at: 0.0)
    var enterFromHidden = true

    package init(tuning: DotScopeTuning = .hud) {
        self.tuning = tuning
        self.leadingInsetSpring = DotSpring(at: tuning.leadingInset)
        self.trailingInsetSpring = DotSpring(at: tuning.trailingInset)
        if tuning.fitsBounds {
            let initialSpan = max(tuning.height, tuning.width - tuning.leadingInset - tuning.trailingInset)
            self.widthSpring = DotSpring(at: initialSpan)
            self.scaleSpring = DotSpring(at: 1.0)
            self.softnessSpring = DotSpring(at: 0.0)
        }
        resizeIfNeeded()
    }

    /// Synthetic speech envelope from `src/dot_scope/scope.rs` (`demo_loudness`) for previews/tests.
    package static func demoLoudness(at time: Float) -> Float {
        let phraseDur: Float = 2.4
        let spokenDur: Float = 1.7
        let phrase = floor(time / phraseDur)
        let t = time - phrase * phraseDur
        let level: Float
        if t > spokenDur {
            level = 0.04
        } else {
            let shape = pow(max(0.0, sin(.pi * t / spokenDur)), 0.4)
            let rate = tau * (4.3 + 0.6 * sin(phrase * 1.7))
            let syllable = 0.5 + 0.5 * sin(rate * t + phrase)
            let stress = 0.75 + 0.25 * sin(tau * 1.1 * t + 2.0 * phrase)
            level = min(1.0, max(0.0, 0.08 + 0.82 * shape * pow(syllable, 1.6) * stress))
        }
        return -58.0 + 28.0 * level
    }

    package static func loudness(fromNormalized level: Float) -> Float {
        let clamped = min(1.0, max(0.0, level))
        return clamped <= 0.001 ? -90.0 : (-54.0 + 34.0 * clamped)
    }

    package func restart(reduceMotion: Bool) {
        let savedAuto = auto
        let currentTuning = tuning
        stage = .recording
        elapsed = 0
        speedAtDone = 0
        doneFrom = 0
        flowOffset = 0
        flowTurn = 0
        auto = savedAuto
        level = 0
        voices = (Voice(), Voice())
        traces = (
            Trace(phases: SIMD4<Float>(0.1, 1.7, 3.3, 4.6)),
            Trace(phases: SIMD4<Float>(2.4, 0.6, 5.1, 1.9))
        )
        live = 0
        carrier = 0
        time = 0
        steps = 0
        pending = 0
        self.reduceMotion = reduceMotion
        enterFromHidden = true
        grid = 0
        leadingInsetSpring = DotSpring(at: currentTuning.leadingInset)
        trailingInsetSpring = DotSpring(at: currentTuning.trailingInset)
        if currentTuning.fitsBounds {
            let span = max(currentTuning.height, currentTuning.width - currentTuning.leadingInset - currentTuning.trailingInset)
            widthSpring = DotSpring(at: span)
            scaleSpring = DotSpring(at: 1.0)
            softnessSpring = DotSpring(at: 0.0)
        } else {
            widthSpring = DotSpring(at: Self.startWidth)
            scaleSpring = DotSpring(at: Self.hiddenScale)
            softnessSpring = DotSpring(at: Self.hiddenSoftness)
        }
        opacitySpring = DotSpring(at: 0.0)
        coolSpring = DotSpring(at: 0.0)
        failSpring = DotSpring(at: 0.0)
        columns = 0
        rows = 0
        tuning = currentTuning
        resizeIfNeeded()
        if reduceMotion {
            scaleSpring.jump(1.0)
            softnessSpring.jump(0.0)
            widthSpring.jump(expectedTargetWidth(for: stage))
        }
    }

    /// Updates tuning. Jumps layout springs ONLY on initial fit (`jumpLayout`) or Reduce Motion;
    /// subsequent inset and width changes glide smoothly on the 240 Hz spring solver.
    package func tune(_ newTuning: DotScopeTuning, jumpLayout: Bool = false) {
        guard tuning != newTuning else { return }
        let widthChanged = abs(newTuning.width - tuning.width) > 0.5
        tuning = newTuning
        resizeIfNeeded()
        if jumpLayout || reduceMotion {
            leadingInsetSpring.jump(newTuning.leadingInset)
            trailingInsetSpring.jump(newTuning.trailingInset)
            if newTuning.fitsBounds {
                widthSpring.jump(expectedTargetWidth(for: stage))
            }
            if steps > 0 {
                beam(hb: Self.stepDt * 2.0)
            }
        } else if widthChanged, newTuning.fitsBounds {
            widthSpring.jump(max(newTuning.height, newTuning.width - leadingInsetSpring.x - trailingInsetSpring.x))
            if steps > 0 {
                beam(hb: Self.stepDt * 2.0)
            }
        }
    }

    func expectedTargetWidth(for targetStage: DotScopeStage) -> Float {
        if tuning.fitsBounds {
            return max(tuning.height, tuning.width - leadingInsetSpring.target - trailingInsetSpring.target)
        }
        return switch targetStage {
        case .idle: tuning.idleWidth
        case .recording: tuning.width
        case .processing, .done: tuning.processingWidth
        case .failed: widthSpring.target
        }
    }

    package var settled: Bool {
        opacitySpring.target == 0.0 && opacitySpring.x < 0.002
    }

    package var isIdleSettled: Bool {
        let targetSpan = expectedTargetWidth(for: .idle)
        return stage == .idle
            && elapsed >= 0.55
            && abs(widthSpring.x - targetSpan) < 0.35
            && abs(opacitySpring.x - 1.0) < 0.01
            && abs(coolSpring.x) < 0.01
            && abs(failSpring.x) < 0.01
            && abs(live - Self.idleLiveTarget) < 0.06
            && abs(leadingInsetSpring.x - tuning.leadingInset) < 0.35
            && abs(trailingInsetSpring.x - tuning.trailingInset) < 0.35
            && abs(leadingInsetSpring.v) < 1.0
            && abs(trailingInsetSpring.v) < 1.0
    }

    package var elapsedTime: Float {
        time
    }

    package var pose: DotScopePose {
        let activeSpan = max(widthSpring.x, tuning.height)
        let plateWidth = tuning.fitsBounds ? tuning.width : activeSpan
        let activeCenter = tuning.fitsBounds ? (leadingInsetSpring.x - trailingInsetSpring.x) * 0.5 : 0.0
        return DotScopePose(
            width: plateWidth,
            height: tuning.height,
            activeSpan: activeSpan,
            activeCenter: activeCenter,
            leadingInset: max(0.0, leadingInsetSpring.x),
            trailingInset: max(0.0, trailingInsetSpring.x),
            opacity: min(1.0, max(0.0, opacitySpring.x)),
            scale: tuning.fitsBounds ? 1.0 : max(0.01, scaleSpring.x),
            softness: tuning.fitsBounds ? 0.0 : min(Self.hiddenSoftness, max(0.0, softnessSpring.x)),
            cool: min(1.0, max(0.0, coolSpring.x)),
            fail: min(1.0, max(0.0, failSpring.x)),
            glow: ((traces.0.glow + traces.1.glow) * 0.5) * tuning.glow,
            grid: grid,
            live: live
        )
    }

    package func advance(
        dt: Float,
        stage targetStage: DotScopeStage,
        visible: Bool,
        loudness: Float,
        reduceMotion: Bool
    ) {
        if targetStage != stage {
            if stage == .idle {
                enterFromHidden = false
            }
            if targetStage == .done {
                armDone()
            }
            if targetStage == .processing {
                flowOffset = -widthSpring.x * 0.5 - 4.0
            }
            stage = targetStage
            elapsed = 0
        }
        self.reduceMotion = reduceMotion
        pending += min(0.25, max(0.0, dt))
        var steppedSteps = 0
        while pending + 1e-6 >= Self.stepDt {
            pending = max(0.0, pending - Self.stepDt)
            stepOnce(visible: visible, loudness: loudness, reduceMotion: reduceMotion)
            steppedSteps += 1
        }
        if steppedSteps > 0 {
            beam(hb: Float(steppedSteps) * Self.stepDt)
        }
    }

    private func resizeIfNeeded() {
        let cols = max(1, min(DotScopeTuning.maxColumns, tuning.columns))
        let rws = max(1, min(DotScopeTuning.maxRows, min(tuning.rows, DotScopeTuning.maxDots / cols)))
        guard cols != columns || rws != rows else { return }
        columns = cols
        rows = rws
        let dotCount = cols * rws
        let sampleCount = (cols - 1) * Self.samplesPerColumn + 1
        head0 = Array(repeating: 0, count: dotCount)
        head1 = Array(repeating: 0, count: dotCount)
        tail0 = Array(repeating: 0, count: dotCount)
        tail1 = Array(repeating: 0, count: dotCount)
        ys0 = Array(repeating: 0, count: sampleCount)
        ys1 = Array(repeating: 0, count: sampleCount)
        bright0 = Array(repeating: 0, count: sampleCount)
        bright1 = Array(repeating: 0, count: sampleCount)
        dots = Array(repeating: .zero, count: dotCount)
        packedDots = Array(repeating: .zero, count: dotCount)
    }

    var workPeriod: Float {
        2.0 * max(0.05, tuning.shimmerPass)
    }

    var flowSpacing: Float {
        let refWidth = tuning.fitsBounds ? max(96.0, widthSpring.x * 0.45) : tuning.processingWidth
        return Self.flowSpacingFactor * refWidth
    }

    private var flowSpeed: Float {
        flowSpacing / workPeriod
    }

    private var flowTurnHz: Float {
        flowSpeed * tuning.helixCycles / max(1.0, widthSpring.x)
    }

    private var pulseSpeed: Float {
        (widthSpring.x * 0.5 + 12.0) / (1.4 * workPeriod)
    }

    private func armDone() {
        speedAtDone = 1.5 * pulseSpeed
        doneFrom = stage == .processing ? elapsed : 0.0
    }

    private func stepOnce(visible: Bool, loudness: Float, reduceMotion: Bool) {
        let h = Self.stepDt
        let isRecording = stage == .recording && visible
        let inputLevel: Float
        if isRecording {
            if tuning.autoLevel {
                level = auto.step(
                    loudness: loudness,
                    dt: h,
                    release: tuning.autoRelease,
                    noiseFloor: tuning.noiseFloor
                )
            } else {
                level = min(1.0, max(0.0, (loudness + 40.0) / 30.0))
            }
            inputLevel = min(1.0, max(0.0, level * tuning.gain))
        } else {
            level = 0
            inputLevel = 0
        }

        voices.0.step(raw: inputLevel, h: h)
        voices.1.step(raw: inputLevel * 0.85, h: h)

        let liveTarget: Float = if isRecording {
            1.0
        } else if stage == .idle && visible {
            Self.idleLiveTarget
        } else {
            0.0
        }
        let liveTau: Float = liveTarget > live ? 0.22 : 0.36
        live += (liveTarget - live) * (1.0 - exp(-h / liveTau))

        let speed: Float = reduceMotion ? 0.0 : tuning.braidSpeed
        traces.0.tick(voice: voices.0, live: live, speed: speed, tuning: tuning, h: h)
        traces.1.tick(voice: voices.1, live: live, speed: speed, tuning: tuning, h: h)

        let energy = max(voices.0.energy, voices.1.energy)
        let working = (stage == .processing || stage == .done)
        flowTurn += ((working ? 1.0 : 0.0) - flowTurn) * (1.0 - exp(-h / 0.25))
        if working {
            flowOffset += flowSpeed * h
        }

        let rest = Self.carrierRest + 0.22 * energy
        let turn = rest + (flowTurnHz - rest) * flowTurn
        carrier = (carrier + h * Self.tau * turn * speed).truncatingRemainder(dividingBy: Self.tau)

        let fade = DotSpringSpec(duration: tuning.transition, bounce: 0.0)
        let bouncy = DotSpringSpec(duration: tuning.transition, bounce: tuning.bounce)

        if reduceMotion {
            leadingInsetSpring.jump(tuning.leadingInset)
            trailingInsetSpring.jump(tuning.trailingInset)
        } else {
            leadingInsetSpring.step(to: tuning.leadingInset, spec: fade, dt: h)
            trailingInsetSpring.step(to: tuning.trailingInset, spec: fade, dt: h)
        }

        let targetWidth: Float = if tuning.fitsBounds {
            max(tuning.height, tuning.width - leadingInsetSpring.x - trailingInsetSpring.x)
        } else {
            expectedTargetWidth(for: stage)
        }
        let coolTarget: Float = (stage == .processing || stage == .done) ? 1.0 : 0.0
        let failTarget: Float = stage == .failed ? 1.0 : 0.0
        let shownTarget: Float = visible ? 1.0 : 0.0

        if reduceMotion {
            widthSpring.jump(targetWidth)
            scaleSpring.jump(1.0)
            softnessSpring.jump(0.0)
            opacitySpring.step(to: shownTarget, spec: .reducedFade, dt: h)
            coolSpring.step(to: coolTarget, spec: .reducedFade, dt: h)
            failSpring.step(to: failTarget, spec: .reducedFade, dt: h)
        } else {
            widthSpring.step(to: targetWidth, spec: tuning.fitsBounds ? fade : bouncy, dt: h)
            opacitySpring.step(to: shownTarget, spec: fade, dt: h)
            scaleSpring.step(to: visible ? 1.0 : Self.hiddenScale, spec: bouncy, dt: h)
            softnessSpring.step(to: visible ? 0.0 : Self.hiddenSoftness, spec: fade, dt: h)
            coolSpring.step(to: coolTarget, spec: fade, dt: h)
            failSpring.step(to: failTarget, spec: fade, dt: h)
        }

        elapsed += h
        time += h
        steps &+= 1
    }
}
