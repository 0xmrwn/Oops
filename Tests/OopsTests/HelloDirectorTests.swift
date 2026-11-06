import Foundation
@testable import Oops
import Testing

@MainActor struct HelloDirectorTests {
    @Test func `skipping dismisses the desktop and replay restores it`() async throws {
        let director = HelloDirector()
        defer { director.stop() }
        #expect(!director.finaleReady)
        #expect(!director.desktopDismissed)
        let lid = director.finaleLid, look = director.finaleLook
        director.skip()
        #expect(director.finaleReady)
        #expect(director.stage == .finale)
        // With no hosted view, the fade completion runs immediately.
        #expect(director.desktopDismissed)
        #expect(director.finaleLid == lid)
        #expect(director.finaleLook == look)

        director.play()
        let deadline = ContinuousClock.now + .seconds(1)
        while director.stage != .entrance, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(director.stage == .entrance)
        #expect(!director.desktopDismissed)
        #expect(!director.finaleReady)
    }

    @Test func `cancelling a pending blink leaves the resting gaze alone`() async {
        let director = HelloDirector()
        let lid = director.finaleLid, look = director.finaleLook
        let blink = Task { try await director.blink() }
        await Task.yield()
        blink.cancel()
        do {
            try await blink.value
            Issue.record("The blink ignored cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected blink failure: \(error)")
        }
        #expect(director.finaleLid == lid)
        #expect(director.finaleLook == look)
    }
}
