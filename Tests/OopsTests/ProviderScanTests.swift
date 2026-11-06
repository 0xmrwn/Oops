import Foundation
@testable import Oops
import OopsCore
import Testing

@MainActor struct ProviderScanTests {
    @MainActor private final class Script {
        struct Wait {
            let duration: Duration
            var continuation: CheckedContinuation<Void, Never>?
        }

        var instant = ContinuousClock.now
        var detections = 0
        var detection: CheckedContinuation<ProviderFindings, Never>?
        var waits: [Wait] = []

        func detect() async -> ProviderFindings {
            detections += 1
            return await withCheckedContinuation { detection = $0 }
        }

        func pause(_ duration: Duration) async throws {
            try Task.checkCancellation()
            guard duration > .zero else { return }
            await withCheckedContinuation { waits.append(Wait(duration: duration, continuation: $0)) }
            try Task.checkCancellation()
        }

        func step() -> ProviderStep {
            ProviderStep(preferences: nil, detection: { await self.detect() }, pause: { try await self.pause($0) }, now: { self.instant })
        }

        func reached(_ count: Int) async throws {
            for _ in 0..<1000 {
                if waits.count >= count { return }
                await Task.yield()
            }
            try #require(waits.count >= count, "The provider step did not reach its next pause")
        }

        func settle() async { for _ in 0..<50 { await Task.yield() } }

        func resume(_ index: Int) {
            waits[index].continuation?.resume(); waits[index].continuation = nil
        }

        func finish(_ findings: ProviderFindings = ProviderFindings()) {
            detection?.resume(returning: findings); detection = nil
        }

        func cleanUp(_ step: ProviderStep) {
            step.stop(); finish()
            for index in waits.indices { resume(index) }
        }
    }

    @Test func `reducing motion stops subsequent decorative gaze writes`() async throws {
        let script = Script(), step = script.step()
        defer { script.cleanUp(step) }
        step.start()
        let scan = Task { await step.scan(step.scanActivity(visible: true, reduceMotion: false)) }
        defer { scan.cancel() }
        try await script.reached(1)
        #expect(script.detections == 1)
        #expect(script.waits[0].duration == .seconds(0.55))
        #expect(step.look.width == 0.85)
        scan.cancel()
        let reduced = step.scanActivity(visible: true, reduceMotion: true)
        await step.scan(reduced)
        let gaze = step.look
        #expect(step.reduceMotion)
        #expect(gaze.width == 0)
        script.resume(0)
        await scan.value
        #expect(script.waits.count == 1)
        #expect(step.look == gaze)

        let resumed = Task { await step.scan(step.scanActivity(visible: true, reduceMotion: false)) }
        defer { resumed.cancel() }
        try await script.reached(2)
        #expect(!step.reduceMotion)
        #expect(step.look.width == 0.85)
        #expect(script.detections == 1)
        script.resume(1)
        try await script.reached(3)
        #expect(step.look.width == -0.85)
        #expect(script.waits[2].duration == .seconds(0.55))

        // A cancelled older view task must not put the cached preference back.
        let obsolete = Task { await step.scan(reduced) }
        obsolete.cancel()
        await obsolete.value
        #expect(!step.reduceMotion)
    }

    @Test func `opening API setup stops the detection scan`() async throws {
        let script = Script(), step = script.step()
        defer { script.cleanUp(step) }
        step.start()
        let activity = step.scanActivity(visible: true, reduceMotion: false)
        let scan = Task { await step.scan(activity) }
        defer { scan.cancel() }
        try await script.reached(1)
        let gaze = step.look
        step.openAPI()
        let api = step.scanActivity(visible: true, reduceMotion: false)
        #expect(api != activity)
        scan.cancel()
        await step.scan(api)
        script.resume(0)
        await scan.value
        #expect(script.waits.count == 1)
        #expect(step.look == gaze)
        #expect(script.detections == 1)

        step.backFromAPI()
        let resumed = Task { await step.scan(step.scanActivity(visible: true, reduceMotion: false)) }
        defer { resumed.cancel() }
        try await script.reached(2)
        #expect(step.look.width == 0.85)
        resumed.cancel()
        await step.scan(step.scanActivity(visible: false, reduceMotion: false))
        let hidden = step.look
        script.resume(1)
        await resumed.value
        #expect(script.waits.count == 2)
        #expect(step.look == hidden)

        let visibleAgain = Task { await step.scan(step.scanActivity(visible: true, reduceMotion: false)) }
        defer { visibleAgain.cancel() }
        try await script.reached(3)
        #expect(step.look.width == 0.85)
        #expect(script.detections == 1)
    }

    @Test func `reduced motion preserves detection minimum reveal rows and proof state`() async throws {
        let script = Script(), step = script.step()
        defer { script.cleanUp(step) }
        step.start()
        await step.scan(step.scanActivity(visible: true, reduceMotion: true))
        await script.settle()
        #expect(script.detections == 1)
        #expect(script.waits.isEmpty)
        #expect(step.looking)
        #expect(step.reduceMotion)

        script.instant = script.instant.advanced(by: .milliseconds(400))
        script.finish()
        try await script.reached(1)
        #expect(script.waits[0].duration == .milliseconds(800))
        #expect(step.looking)
        #expect(step.shown.isEmpty)
        script.resume(0)
        try await script.reached(2)
        #expect(!step.looking)
        #expect(step.shown == [.chatGPT])
        #expect(script.waits[1].duration == .seconds(0.17))
        script.resume(1)
        try await script.reached(3)
        #expect(step.shown == [.chatGPT, .claude])
        #expect(script.waits[2].duration == .seconds(0.17))
        script.resume(2)
        await script.settle()
        #expect(step.proof == .idle)
        #expect(step.selected == nil)
        #expect(script.detections == 1)

        let resting = step.look
        let reduced = step.scanActivity(visible: true, reduceMotion: true)
        let normal = step.scanActivity(visible: true, reduceMotion: false)
        #expect(!normal.pending)
        #expect(normal != reduced)
        await step.scan(normal)
        #expect(!step.reduceMotion)
        #expect(script.waits.count == 3)
        #expect(step.look == resting)
        step.start()
        await script.settle()
        #expect(script.detections == 1)
    }

    @Test func `stopping rejects stale scan activity while detection is suspended`() async throws {
        let script = Script(), step = script.step()
        defer { script.cleanUp(step) }
        step.start()
        let activity = step.scanActivity(visible: true, reduceMotion: false)
        let scan = Task { await step.scan(activity) }
        defer { scan.cancel() }
        try await script.reached(1)
        let gaze = step.look
        step.stop()
        #expect(!step.scanActivity(visible: true, reduceMotion: false).pending)
        scan.cancel()
        script.resume(0)
        await scan.value
        await step.scan(activity)
        #expect(step.look == gaze)
        #expect(script.waits.count == 1)
        #expect(script.detections == 1)
    }

    @Test func `motion can resume when the step first appeared with Reduce Motion enabled`() async throws {
        let script = Script(), step = script.step()
        defer { script.cleanUp(step) }
        step.start()
        let reduced = step.scanActivity(visible: true, reduceMotion: true)
        await step.scan(reduced)
        await script.settle()
        #expect(script.waits.isEmpty)
        #expect(step.reduceMotion)
        #expect(script.detections == 1)

        let normal = step.scanActivity(visible: true, reduceMotion: false)
        #expect(normal != reduced)
        #expect(normal.pending)
        let scan = Task { await step.scan(normal) }
        defer { scan.cancel() }
        try await script.reached(1)
        #expect(!step.reduceMotion)
        #expect(step.look.width == 0.85)
        #expect(script.waits[0].duration == .seconds(0.55))
        #expect(script.detections == 1)
    }

    @Test func `slow detection does not add another minimum reveal delay`() async throws {
        let script = Script(), step = script.step()
        defer { script.cleanUp(step) }
        step.start()
        await step.scan(step.scanActivity(visible: true, reduceMotion: true))
        await script.settle()
        script.instant = script.instant.advanced(by: .seconds(2))
        script.finish()
        try await script.reached(1)
        #expect(!step.looking)
        #expect(step.shown == [.chatGPT])
        #expect(script.waits[0].duration == .seconds(0.17))
        #expect(script.detections == 1)
    }
}
