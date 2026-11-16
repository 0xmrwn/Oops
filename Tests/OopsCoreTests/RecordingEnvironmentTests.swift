import Foundation
@testable import OopsCore
import Synchronization
import Testing

// Ported from the tests of Hex's `src/audio/recording_environment.rs` at v3.4.0. Hex's sessions also held idle
// sleep and told dictations from captures; Oops does neither, so a capture here is a second session.

/// What happened, in order, from any thread.
final class Recorded<Item: Sendable>: Sendable {
    private let items = Mutex<[Item]>([])
    func append(_ item: Item) { items.withLock { $0.append(item) } }
    var all: [Item] { items.withLock { $0 } }
    /// What was recorded since the last call.
    func take() -> [Item] {
        items.withLock { items in
            defer { items = [] }
            return items
        }
    }
}

/// A controller whose effects are only recorded: nothing touches output or media.
final class ObservedEnvironment: Sendable {
    enum Event: Equatable, Sendable {
        case held(RecordingEnvironmentEffect)
        case restored(RecordingEnvironmentEffect)
        case then
    }

    final class Observed: RecordingEnvironmentHold {
        let effect: RecordingEnvironmentEffect
        let events: Recorded<Event>
        init(_ effect: RecordingEnvironmentEffect, _ events: Recorded<Event>) { self.effect = effect; self.events = events }
        func restore() { events.append(.restored(effect)) }
    }

    private let events = Recorded<Event>()
    let controller: RecordingEnvironmentController

    init() {
        let events = events
        controller = RecordingEnvironmentController { effect in
            events.append(.held(effect))
            return Observed(effect, events)
        }
    }

    func record(_ event: Event) { events.append(event) }

    /// What the environment did since the last call, once every command sent before it was handled.
    func settled() -> [Event] {
        controller.settle()
        return events.take()
    }
}

struct RecordingEnvironmentTests {
    @Test func `quitting waits for the last session to restore`() {
        final class SlowRestore: RecordingEnvironmentHold {
            let effect: RecordingEnvironmentEffect, restored: Recorded<RecordingEnvironmentEffect>
            init(_ effect: RecordingEnvironmentEffect, _ restored: Recorded<RecordingEnvironmentEffect>) { self.effect = effect; self.restored = restored }
            func restore() {
                Thread.sleep(forTimeInterval: 0.1)
                restored.append(effect)
            }
        }
        let restored = Recorded<RecordingEnvironmentEffect>()
        let controller = RecordingEnvironmentController { SlowRestore($0, restored) }
        let session = controller.begin(.mute)
        session.end()
        #expect(controller.waitUntilRestored(timeout: .seconds(2)))
        #expect(restored.all == [.mute])
    }

    @Test func `sessions are harmless after the environment worker disconnects`() {
        var controller: RecordingEnvironmentController? = RecordingEnvironmentController { _ in nil }
        let first = controller!.begin(.mute), second = controller!.begin(.mute)
        controller = nil
        first.end()
        let ran = DispatchSemaphore(value: 0)
        second.end { ran.signal() }
        #expect(ran.wait(timeout: .now() + 2) == .success, "the callback still runs")
        let again = DispatchSemaphore(value: 0)
        second.end { again.signal() }
        #expect(again.wait(timeout: .now()) == .success, "a second end only runs its callback")
    }

    @Test func `overlapping sessions restore only after the last session`() {
        let observed = ObservedEnvironment(), controller = observed.controller
        #expect(observed.settled().isEmpty)

        let first = controller.begin(.mute)
        let second = controller.begin(.mute)
        #expect(observed.settled() == [.held(.mute)])

        first.end()
        #expect(observed.settled().isEmpty)

        let third = controller.begin(.mute)
        second.end()
        #expect(observed.settled().isEmpty)

        third.end()
        #expect(observed.settled() == [.restored(.mute)])
    }

    @Test func `a new session reacquires the environment after restoration`() {
        let observed = ObservedEnvironment(), controller = observed.controller
        for _ in 0 ..< 2 {
            let session = controller.begin(.lowerAudio)
            #expect(observed.settled() == [.held(.duck)])
            session.end()
            #expect(observed.settled() == [.restored(.duck)])
        }
        _ = controller.begin(.nothing)
        #expect(observed.settled().isEmpty, "Do nothing holds nothing")
    }

    @Test func `a dictation inside a capture leaves the capture quiet`() {
        let observed = ObservedEnvironment(), controller = observed.controller
        let capture = controller.begin(.mute)
        #expect(observed.settled() == [.held(.mute)])

        let dictating = controller.begin(.mute)
        #expect(observed.settled().isEmpty)
        // The callback waits for no unmute: the capture keeps output muted.
        let ran = Recorded<Bool>()
        dictating.end { ran.append(true) }
        #expect(observed.settled().isEmpty)
        #expect(ran.all == [true])

        capture.end()
        #expect(observed.settled() == [.restored(.mute)])
    }

    @Test func `a capture inside a dictation outlives it`() {
        let observed = ObservedEnvironment(), controller = observed.controller
        let dictating = controller.begin(.mute)
        #expect(observed.settled() == [.held(.mute)])

        let capture = controller.begin(.mute)
        #expect(observed.settled().isEmpty)

        dictating.end()
        #expect(observed.settled().isEmpty)

        capture.end()
        #expect(observed.settled() == [.restored(.mute)])
    }

    @Test func `a capture that ends first leaves the dictation quiet`() {
        let observed = ObservedEnvironment(), controller = observed.controller
        let dictating = controller.begin(.mute)
        let capture = controller.begin(.mute)
        #expect(observed.settled() == [.held(.mute)])

        capture.end()
        #expect(observed.settled().isEmpty)

        dictating.end()
        #expect(observed.settled() == [.restored(.mute)])
    }

    @Test func `different policies compose and each restores its own`() {
        let observed = ObservedEnvironment(), controller = observed.controller
        let capture = controller.begin(.pauseMedia)
        #expect(observed.settled() == [.held(.pause)])

        let dictating = controller.begin(.mute)
        #expect(observed.settled() == [.held(.mute)])
        // The capture keeps media paused.
        dictating.end()
        #expect(observed.settled() == [.restored(.mute)])

        let lowering = controller.begin(.lowerAudio)
        #expect(observed.settled() == [.held(.duck)])
        lowering.end()
        #expect(observed.settled() == [.restored(.duck)])

        capture.end()
        #expect(observed.settled() == [.restored(.pause)])
    }

    @Test func `a callback runs after unmuting and before resuming media`() {
        for (audio, expected) in [
            (DictationWhileDictating.mute, [ObservedEnvironment.Event.restored(.mute), .then]),
            (.lowerAudio, [.restored(.duck), .then]),
            (.pauseMedia, [.then, .restored(.pause)])
        ] {
            let observed = ObservedEnvironment()
            let session = observed.controller.begin(audio)
            _ = observed.settled()
            session.end { observed.record(.then) }
            #expect(observed.settled() == expected, "\(audio)")
        }
    }

    @Test func `controller moves and clones do not restore a live session`() {
        let observed = ObservedEnvironment()
        var controller: RecordingEnvironmentController? = observed.controller
        let session = controller!.begin(.mute)
        #expect(observed.settled() == [.held(.mute)])

        var cloned = controller
        controller = nil
        #expect(observed.settled().isEmpty)

        let overlapping = cloned!.begin(.mute)
        cloned = nil
        session.end()
        overlapping.settle()
        #expect(observed.settled().isEmpty)

        overlapping.end()
        #expect(observed.settled() == [.restored(.mute)])
    }
}
