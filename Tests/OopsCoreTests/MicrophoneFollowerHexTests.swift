@testable import OopsCore
import Testing

/// Hex's tests of when `RecoveringAudioInput` switches microphones (`src/audio.rs` at v3.4.0), under their upstream
/// names. Hex opens on a worker thread and `settle` polls until it finishes; here resolving is synchronous, so
/// `settle` polls once and hands the follower what the opener found. Hex's `keep` is the open input's UID.
struct MicrophoneFollowerHexTests {
    typealias InUse = MicrophoneFollower.InUse

    @Test func `a default change switches only while capture is idle`() {
        var systemDefault = "KIT PODS", generation: UInt64 = 0
        let opener = { (keep: String?) -> MicrophoneFollower.Resolved in
            keep == systemDefault ? .unchanged(.inUse) : .input(InUse(uid: systemDefault, name: systemDefault))
        }
        var input = MicrophoneFollower(selected: nil, routeGeneration: generation)
        input.opened(InUse(uid: "KIT PODS", name: "KIT PODS"), routeGeneration: generation, at: .now)

        // The OS default changes during a recording: nothing opens yet.
        systemDefault = "MacBook Pro Microphone"
        generation += 1
        #expect(settle(&input, generation: generation, idle: false, opener: opener) == .timeout)
        #expect(input.isPending)
        #expect(input.input?.name == "KIT PODS")

        // Once capture is idle, the new default replaces the old one.
        #expect(settle(&input, generation: generation, idle: true, opener: opener) == .reopened)
        #expect(input.input?.name == "MacBook Pro Microphone")

        // A device change that leaves the default alone keeps the stream.
        generation += 1
        #expect(settle(&input, generation: generation, idle: true, opener: opener) == .timeout)
        #expect(!input.isPending)
        #expect(input.input?.name == "MacBook Pro Microphone")
    }

    @Test func `a missing selection uses the default until it returns`() {
        let (follower, connected, started) = standingIn(.unlisted, reportsNewDevices: false)
        var input = follower
        #expect(input.nextAttempt == started + MicrophoneFollower.retryInitial)

        // Still missing: the default keeps running and the next look backs off.
        input.nextAttempt = .now
        #expect(settle(&input, generation: 0, idle: true, opener: connected.opener) == .timeout)
        #expect(input.input?.name == "KIT PODS")
        #expect(input.selectionRetry == MicrophoneFollower.retryInitial * 4)

        connected.value = true
        input.nextAttempt = .now
        #expect(settle(&input, generation: 0, idle: true, opener: connected.opener) == .reopened)
        #expect(input.input?.name == "USB Mic")
        #expect(input.input?.selection == .inUse)
        #expect(input.nextAttempt == nil)
        #expect(input.selectedUID == "USB Mic")
    }

    @Test func `where the os reports new devices only a failed open is retried`() {
        // An unlisted microphone waits for the OS to report a device.
        let (follower, connected, _) = standingIn(.unlisted, reportsNewDevices: true)
        var input = follower
        #expect(input.nextAttempt == nil)
        #expect(settle(&input, generation: 0, idle: true, opener: connected.opener) == .timeout)
        #expect(!input.isPending)
        connected.value = true
        #expect(settle(&input, generation: 1, idle: true, opener: connected.opener) == .reopened)
        #expect(input.input?.name == "USB Mic")

        // A listed microphone that would not open is looked at again.
        let (unopenable, _, started) = standingIn(.unopenable, reportsNewDevices: true)
        #expect(unopenable.nextAttempt == started + MicrophoneFollower.retryInitial)
    }

    @Test func `closed input applies selection without opening`() {
        var input = MicrophoneFollower(selected: "Old microphone", routeGeneration: 0)
        input.requestSelection("Next microphone", at: .now)
        #expect(input.input == nil)
        #expect(input.selectedUID == "Next microphone")
        #expect(!input.isPending)
    }

    @Test func `a microphone picked while open switches at the next idle look`() {
        var input = MicrophoneFollower(selected: nil, routeGeneration: 0)
        input.opened(InUse(uid: "MacBook Pro Microphone", name: "MacBook Pro Microphone"), routeGeneration: 0, at: .now)
        input.requestSelection("AirPods Pro", at: .now)
        let opener = { (_: String?) -> MicrophoneFollower.Resolved in .input(InUse(uid: "AirPods Pro", name: "AirPods Pro")) }
        #expect(settle(&input, generation: 0, idle: false, opener: opener) == .timeout)
        #expect(input.input?.name == "MacBook Pro Microphone")
        #expect(settle(&input, generation: 0, idle: true, opener: opener) == .reopened)
        #expect(input.input?.name == "AirPods Pro")
    }
}

/// Whether the picked "USB Mic" is connected, and what an open finds either way.
private final class Connected {
    var value = false
    let missing: MicrophoneSelection

    init(missing: MicrophoneSelection) { self.missing = missing }

    func opener(_ keep: String?) -> MicrophoneFollower.Resolved {
        let (name, selection) = value ? ("USB Mic", MicrophoneSelection.inUse) : ("KIT PODS", missing)
        return keep == name ? .unchanged(selection) : .input(MicrophoneFollower.InUse(uid: name, name: name, selection: selection))
    }
}

/// An input picked as "USB Mic" that opens once connected and until then stands in with "KIT PODS" for `missing`.
private func standingIn(_ missing: MicrophoneSelection, reportsNewDevices: Bool)
    -> (MicrophoneFollower, Connected, ContinuousClock.Instant) {
    var input = MicrophoneFollower(selected: "USB Mic", routeGeneration: 0, reportsNewDevices: reportsNewDevices)
    let started = ContinuousClock.now
    input.opened(MicrophoneFollower.InUse(uid: "KIT PODS", name: "KIT PODS", selection: missing), routeGeneration: 0, at: started)
    return (input, Connected(missing: missing), started)
}

/// Polls once and, when the follower asks, resolves with `opener`.
private func settle(_ input: inout MicrophoneFollower, generation: UInt64, idle: Bool,
                    opener: (String?) -> MicrophoneFollower.Resolved) -> MicrophoneFollower.Event {
    let now = ContinuousClock.now
    guard input.poll(routeGeneration: generation, captureIdle: idle, at: now) else { return .timeout }
    return input.resolved(opener(input.input?.uid), captureIdle: idle, at: now)
}
