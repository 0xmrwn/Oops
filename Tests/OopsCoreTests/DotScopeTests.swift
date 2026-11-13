@testable import OopsCore
import Testing

// Ported from Hex's `ios/HEXMobileTests/DotScopeTests.swift` (MIT, Copyright (c) 2026 Christopher Langton), keeping
// its test names. See THIRD_PARTY_NOTICES.md. The host-view test is in `OopsTests` (`DotScopeHostTests`).

private func near(_ a: Float, _ b: Float, _ accuracy: Float) -> Bool { abs(a - b) <= accuracy }

struct DotScopeTests {
    @Test func `analytical spring is frame rate independent`() {
        let spec = DotSpringSpec(duration: 0.30, bounce: 0.15)
        var fast = DotSpring(at: 0)
        var slow = DotSpring(at: 0)

        for _ in 0..<240 {
            fast.step(to: 1.0, spec: spec, dt: 1.0 / 240.0)
        }
        for _ in 0..<30 {
            slow.step(to: 1.0, spec: spec, dt: 1.0 / 30.0)
        }

        #expect(near(fast.x, slow.x, 1e-4))
        #expect(near(fast.v, slow.v, 1e-3))
        #expect(near(fast.x, 1.0, 1e-3))
    }

    @Test func `auto level normalizes speech above room floor`() {
        var auto = DotScopeAutoLevel()
        var silentLevel: Float = 1.0
        for _ in 0..<120 {
            silentLevel = auto.step(loudness: -62.0, dt: 1.0 / 240.0, release: 3.0, noiseFloor: -60.0)
        }
        #expect(silentLevel < 0.05)

        var speechLevel: Float = 0.0
        for _ in 0..<60 {
            speechLevel = auto.step(loudness: -28.0, dt: 1.0 / 240.0, release: 3.0, noiseFloor: -60.0)
        }
        #expect(speechLevel > 0.65)
    }

    @Test func `simulation lights braided dots during recording and cools during processing`() {
        let sim = DotScopeSimulation(tuning: .keyboard)
        sim.restart(reduceMotion: false)

        for _ in 0..<60 {
            sim.advance(
                dt: 1.0 / 60.0,
                stage: .recording,
                visible: true,
                loudness: DotScopeSimulation.demoLoudness(at: sim.elapsedTime),
                reduceMotion: false
            )
        }

        let recordingPose = sim.pose
        #expect(recordingPose.opacity > 0.95)
        #expect(near(recordingPose.cool, 0.0, 0.01))
        #expect(recordingPose.live > 0.70)

        let peakDot = sim.dots.map(\.x).max() ?? 0
        #expect(peakDot > 0.45)

        let warmPalette = DotScopePalette.dark(pose: recordingPose)
        #expect(warmPalette.base.x > warmPalette.base.z)

        for _ in 0..<45 {
            sim.advance(
                dt: 1.0 / 60.0,
                stage: .processing,
                visible: true,
                loudness: -120.0,
                reduceMotion: false
            )
        }

        let processingPose = sim.pose
        #expect(processingPose.width < recordingPose.width)
        #expect(processingPose.cool > 0.90)

        let coolPalette = DotScopePalette.dark(pose: processingPose)
        #expect(coolPalette.base.z > coolPalette.base.x)
    }

    @Test func `simulation settles when hidden`() {
        let sim = DotScopeSimulation(tuning: .hud)
        sim.restart(reduceMotion: false)
        sim.advance(dt: 0.4, stage: .recording, visible: true, loudness: -30.0, reduceMotion: false)
        #expect(!sim.settled)

        for _ in 0..<60 {
            sim.advance(dt: 1.0 / 60.0, stage: .done, visible: false, loudness: -120.0, reduceMotion: false)
        }
        #expect(sim.settled)
    }

    @Test func `idle stage settles for zero idle power`() {
        let sim = DotScopeSimulation(tuning: .keyboard)
        sim.restart(reduceMotion: false)
        #expect(!sim.isIdleSettled)

        for _ in 0..<36 {
            sim.advance(dt: 1.0 / 60.0, stage: .idle, visible: true, loudness: -120.0, reduceMotion: false)
        }
        #expect(sim.isIdleSettled)
        #expect(sim.pose.opacity > 0.99)
        #expect(near(sim.pose.width, DotScopeTuning.keyboard.idleWidth, 0.25))
    }

    @Test func `bar tuning fits full width drawable with pixel snapped pitch and odd rows`() {
        let fitted = DotScopeTuning.bar(leadingInset: 49, trailingInset: 79, fade: 16, spacing: 3.2)
            .fitted(pixelWidth: 373 * 3, pixelHeight: 52 * 3, scale: 3.0)

        #expect(fitted.fitsBounds)
        #expect(near(fitted.width, 373.0, 0.01))
        #expect(near(fitted.height, 52.0, 0.01))
        #expect(fitted.columns > 100)
        #expect(fitted.rows % 2 == 1)

        let pxPitch = fitted.spacing * 3.0
        #expect(near(pxPitch, pxPitch.rounded(), 1e-4))

        let sim = DotScopeSimulation(tuning: fitted)
        sim.restart(reduceMotion: false)
        for _ in 0..<48 {
            sim.advance(dt: 1.0 / 60.0, stage: .recording, visible: true, loudness: -29.0, reduceMotion: false)
        }

        let pose = sim.pose
        #expect(near(pose.width, 373.0, 0.01))
        #expect(near(pose.activeSpan, 373.0 - 49.0 - 79.0, 0.5))
        #expect(near(pose.activeCenter, (49.0 - 79.0) * 0.5, 0.25))

        // When recording finishes and buttons clear, processing spans the full bar end to end.
        let fullBar = DotScopeTuning.bar(leadingInset: 0, trailingInset: 0, fade: 16, spacing: 3.2)
            .fitted(pixelWidth: 373 * 3, pixelHeight: 52 * 3, scale: 3.0)
        sim.tune(fullBar)
        for _ in 0..<48 {
            sim.advance(dt: 1.0 / 60.0, stage: .processing, visible: true, loudness: -120.0, reduceMotion: false)
        }
        #expect(near(sim.pose.activeSpan, 373.0, 1.0))
        #expect(near(sim.pose.activeCenter, 0.0, 0.5))
    }

    @Test func `bar idle settles and rewakes when insets change`() {
        let idleBar = DotScopeTuning.bar(leadingInset: 0, trailingInset: 105, fade: 16, spacing: 3.2)
            .fitted(pixelWidth: 373 * 3, pixelHeight: 52 * 3, scale: 3.0)
        let sim = DotScopeSimulation(tuning: idleBar)
        sim.restart(reduceMotion: false)

        for _ in 0..<36 {
            sim.advance(dt: 1.0 / 60.0, stage: .idle, visible: true, loudness: -120.0, reduceMotion: false)
        }
        #expect(sim.isIdleSettled)

        var widerTrigger = idleBar
        widerTrigger.trailingInset = 142
        sim.tune(widerTrigger)
        #expect(!sim.isIdleSettled)

        for _ in 0..<48 {
            sim.advance(dt: 1.0 / 60.0, stage: .idle, visible: true, loudness: -120.0, reduceMotion: false)
        }
        #expect(sim.isIdleSettled)
    }

    @Test func `bar inset updates glide smoothly instead of jumping`() {
        let idleBar = DotScopeTuning.bar(leadingInset: 0, trailingInset: 105)
            .fitted(pixelWidth: 373 * 3, pixelHeight: 44 * 3, scale: 3.0)
        let sim = DotScopeSimulation(tuning: idleBar)
        sim.restart(reduceMotion: false)

        for _ in 0..<42 {
            sim.advance(dt: 1.0 / 60.0, stage: .idle, visible: true, loudness: -120.0, reduceMotion: false)
        }
        #expect(near(sim.pose.leadingInset, 0.0, 0.25))
        #expect(near(sim.pose.trailingInset, 105.0, 0.25))

        // Transitioning to recording retargets both insets on the 0.28s critical spring:
        // after one 60 Hz frame, neither inset may jump all the way to its target.
        let recBar = DotScopeTuning.bar(leadingInset: 45, trailingInset: 77)
            .fitted(pixelWidth: 373 * 3, pixelHeight: 44 * 3, scale: 3.0)
        sim.tune(recBar, jumpLayout: false)
        sim.advance(dt: 1.0 / 60.0, stage: .recording, visible: true, loudness: -30.0, reduceMotion: false)

        #expect(sim.pose.leadingInset > 0.2)
        #expect(sim.pose.leadingInset < 15.0)
        #expect(sim.pose.trailingInset < 104.8)
        #expect(sim.pose.trailingInset > 90.0)

        for _ in 0..<48 {
            sim.advance(dt: 1.0 / 60.0, stage: .recording, visible: true, loudness: -30.0, reduceMotion: false)
        }
        #expect(near(sim.pose.leadingInset, 45.0, 0.35))
        #expect(near(sim.pose.trailingInset, 77.0, 0.35))
    }

    /// Not in Hex: with Reduce Motion the scope takes its still form, as `advance` and `beam` define it. The
    /// layout springs jump instead of gliding, the braid stops turning, and there is no entrance pass.
    @Test func `reduced motion yields the still form`() {
        func run(reduceMotion: Bool) -> DotScopePose {
            let sim = DotScopeSimulation(tuning: .hud)
            sim.restart(reduceMotion: reduceMotion)
            for _ in 0..<6 {
                sim.advance(dt: 1.0 / 60.0, stage: .recording, visible: true, loudness: -30.0, reduceMotion: reduceMotion)
            }
            return sim.pose
        }
        let still = run(reduceMotion: true)
        #expect(still.scale == 1.0)
        #expect(still.softness == 0.0)
        #expect(still.activeSpan == DotScopeTuning.hud.width)
        #expect(still.grid == 1.0)

        let moving = run(reduceMotion: false)
        #expect(moving.scale < 1.0)
        #expect(moving.softness > 0.0)
        #expect(moving.activeSpan < DotScopeTuning.hud.width)
        #expect(moving.grid < 1.0)
    }
}
