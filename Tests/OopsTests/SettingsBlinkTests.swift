import Foundation
@testable import Oops
import Testing

@MainActor struct SettingsBlinkTests {
    @MainActor private final class Pauses {
        struct Wait {
            let duration: Duration
            var continuation: CheckedContinuation<Void, Never>?
        }

        var waits: [Wait] = []

        func pause(_ duration: Duration) async throws {
            await withCheckedContinuation { waits.append(Wait(duration: duration, continuation: $0)) }
            try Task.checkCancellation()
        }

        func reached(_ count: Int) async throws {
            for _ in 0..<1000 {
                if waits.count >= count { return }
                await Task.yield()
            }
            try #require(waits.count >= count, "The blink did not reach its next pause")
        }

        func resume(_ index: Int) {
            waits[index].continuation?.resume()
            waits[index].continuation = nil
        }

        func resumeAll() { for index in waits.indices { resume(index) } }
    }

    @Test func `an inactive companion cannot start a blink`() async {
        let blink = SettingsBlink(pause: { _ in Issue.record("An inactive companion scheduled work") })
        await blink.play(times: 2)
        #expect(blink.lid == 0)
    }

    @Test func `the visible companion keeps the double blink cadence and rejects overlap`() async throws {
        let pauses = Pauses(), blink = SettingsBlink(pause: { try await pauses.pause($0) })
        defer { blink.setActive(false); pauses.resumeAll() }
        blink.setActive(true)
        let run = Task { await blink.play(times: 2) }
        try await pauses.reached(1)
        #expect(blink.lid == 1)
        await blink.play(times: 1)
        #expect(pauses.waits.count == 1)
        pauses.resume(0)
        try await pauses.reached(2)
        #expect(blink.lid == 0)
        pauses.resume(1)
        try await pauses.reached(3)
        #expect(blink.lid == 1)
        pauses.resume(2)
        await run.value
        #expect(blink.lid == 0)
        #expect(pauses.waits.map(\.duration) == [.milliseconds(100), .milliseconds(260), .milliseconds(100)])
    }

    @Test func `hiding or reducing motion opens the lids and stops a double blink`() async throws {
        let pauses = Pauses(), blink = SettingsBlink(pause: { try await pauses.pause($0) })
        defer { blink.setActive(false); pauses.resumeAll() }
        blink.setActive(true)
        let run = Task { await blink.play(times: 2) }
        try await pauses.reached(1)
        blink.setActive(false)
        #expect(blink.lid == 0)
        pauses.resume(0)
        await run.value
        #expect(pauses.waits.count == 1)
        #expect(blink.lid == 0)
        await blink.play(times: 1)
        #expect(pauses.waits.count == 1)
    }

    @Test func `a cancelled old blink cannot clear a newly visible blink`() async throws {
        let pauses = Pauses(), blink = SettingsBlink(pause: { try await pauses.pause($0) })
        defer { blink.setActive(false); pauses.resumeAll() }
        blink.setActive(true)
        let old = Task { await blink.play(times: 1) }
        try await pauses.reached(1)
        blink.setActive(false)
        blink.setActive(true)
        let current = Task { await blink.play(times: 1) }
        try await pauses.reached(2)
        pauses.resume(0)
        await old.value
        #expect(blink.lid == 1)
        await blink.play(times: 1)
        #expect(pauses.waits.count == 2)
        pauses.resume(1)
        await current.value
        #expect(blink.lid == 0)
    }

    @Test func `cancelling the view task also cancels its in progress blink`() async throws {
        let pauses = Pauses(), blink = SettingsBlink(pause: { try await pauses.pause($0) })
        defer { blink.setActive(false); pauses.resumeAll() }
        blink.setActive(true)
        let run = Task { await blink.play(times: 2) }
        try await pauses.reached(1)
        run.cancel()
        pauses.resume(0)
        await run.value
        #expect(pauses.waits.count == 1)
        #expect(blink.lid == 0)
    }
}
