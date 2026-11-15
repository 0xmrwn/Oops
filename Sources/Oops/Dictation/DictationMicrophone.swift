import AVFoundation
import CoreAudio
import OopsCore
import Synchronization

/// The microphone as a dictation's audio source: an `AVAudioEngine` input feeding an `AVAudioSinkNode`.
/// A sink node gets the device's own render blocks (about 10 ms, 512 frames at 48 kHz) where a tap hands
/// over 100 ms at a time whatever size is asked. Its block runs on the real-time audio thread, so it only
/// mixes the block to mono into the ring: no allocation, no lock, no Swift concurrency. The engine is kept
/// between opens, stopped: restarting it delivers audio about 90 ms after the start, a new engine 130 to
/// 220 ms. Stopping it releases the microphone, and the menu bar's microphone indicator goes away.
///
/// Each open chooses the input (`MicrophoneChoice`: the picked microphone, else the system default, passing over
/// a Bluetooth default when Settings asks) and sets it on the engine's input unit, so the engine records from that
/// device whatever the default does next. An open that chooses another device than the engine's builds a new
/// engine. While open, a change of route or setting is noted and acted on only while capture is idle
/// (`MicrophoneFollower`): the source then ends its ring and tells the loss, and the next open uses the new input.
/// An engine that stops by itself (its device went away) ends the ring and tells the loss at once.
final class DictationMicrophone: DictationAudioSource {
    private struct Engine {
        let engine = AVAudioEngine()
        var sink: AVAudioSinkNode?
        var format: AVAudioFormat?
        var ring: DictationAudioRing?
        /// The device set on the engine's input unit.
        var device: AudioDeviceID?
        var isOpen = false
        var observer: any NSObjectProtocol?

        /// Stops listening; the engine is dropped next.
        func discard() {
            engine.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private struct State {
        // Created at the first open, after the access check: touching the input node of an app without
        // access could prompt.
        var engine: Engine?
        var follower = MicrophoneFollower(selected: DictationAudioSettings.microphone(), routeGeneration: MicrophoneWatch.shared.generation)
        var checkScheduled = false
    }

    private let access: @Sendable () -> DictationMicrophoneAccess
    private let state = Mutex(State())
    private let lost = Mutex<(@Sendable () -> Void)?>(nil)
    private let idle = Mutex<@Sendable () async -> Bool>({ false })
    /// Device changes are checked here, never on the thread that posted them: the engine may post while
    /// `open` holds the state's lock.
    private let changes = DispatchQueue(label: "oops.microphone.changes")
    private let watching = Mutex<UUID?>(nil)

    init(access: @escaping @Sendable () -> DictationMicrophoneAccess = { .current }) { self.access = access }

    deinit { if let token = watching.withLock({ $0 }) { MicrophoneWatch.shared.stop(token) } }

    func watchLoss(_ lost: @escaping @Sendable () -> Void) { self.lost.withLock { $0 = lost } }

    /// `idle` says whether capture is idle, so the open microphone may switch input: nothing records, no press
    /// waits for audio, no release waits for its tail. Until told, it never switches while open.
    func watchCaptureIdle(_ idle: @escaping @Sendable () async -> Bool) { self.idle.withLock { $0 = idle } }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        let access = access()
        guard access == .granted else { throw .microphoneAccess(access) }
        watchRoute()
        // Read before the devices, so a change while they are read is seen as one afterwards.
        let generation = MicrophoneWatch.shared.generation
        let snapshot = MicrophoneDevices.snapshot(), selected = DictationAudioSettings.microphone()
        let route = snapshot.route(avoidBluetooth: DictationAudioSettings.avoidBluetooth())
        let check: @Sendable () -> Void = { [weak self] in self?.engineMayHaveStopped() }
        return try state.withLock { state throws(DictationAudioError) in
            state.follower.requestSelection(selected, at: .now)
            let plan = try Self.plan(selected: selected, snapshot, route)
            func start(_ plan: MicrophonePlan) throws(DictationAudioError) -> (Double, MicrophoneFollower.InUse) {
                try Self.start(plan, snapshot, into: ring, engine: &state.engine, check: check, changes: changes)
            }
            let (rate, opened) = if case .named = plan.target {
                // A picked microphone that will not open falls back to what System default would use, and is
                // looked for again.
                try MicrophoneChoice.openSelected(retrying: true, open: { () throws(DictationAudioError) in try start(plan) }, openDefault: {
                    () throws(DictationAudioError) in
                    var fallback = try Self.plan(selected: nil, snapshot, route)
                    fallback.selection = .unopenable
                    return try start(fallback)
                }, sleep: { Thread.sleep(forTimeInterval: Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) })
            } else {
                try start(plan)
            }
            state.follower.opened(opened, routeGeneration: generation, at: .now)
            return rate
        }
    }

    func close() {
        state.withLock { state in
            state.engine?.engine.stop()
            state.engine?.isOpen = false
            state.follower.closed()
        }
    }

    private static func plan(selected: String?, _ snapshot: MicrophoneDevices.Snapshot,
                             _ route: MicrophoneRoute) throws(DictationAudioError) -> MicrophonePlan {
        switch MicrophoneChoice.resolve(selected: selected, inputs: snapshot.inputs, defaultUID: snapshot.defaultUID, route: route) {
        case let .success(plan): plan
        case .failure(.lidClosed): throw .failed("the built-in microphone is off while the lid is closed")
        case .failure(.noMicrophone): throw .noInput
        }
    }

    /// Starts the engine on the plan's device, building a new engine when the kept one records from another.
    private static func start(_ plan: MicrophonePlan, _ snapshot: MicrophoneDevices.Snapshot, into ring: DictationAudioRing,
                              engine state: inout Engine?, check: @escaping @Sendable () -> Void,
                              changes: DispatchQueue) throws(DictationAudioError) -> (Double, MicrophoneFollower.InUse) {
        guard let target = snapshot.resolve(plan) else { throw .noInput }
        if let stale = state, stale.device != target.device { stale.discard(); state = nil }
        var current = state ?? Engine()
        defer { state = current }
        let engine = current.engine
        if current.observer == nil {
            current.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                      queue: nil) { _ in changes.async(execute: check) }
        }
        engine.stop()
        current.isOpen = false
        if current.device == nil {
            guard let unit = engine.inputNode.audioUnit else { throw .noInput }
            var device = target.device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw .failed("the microphone could not be selected: \(status)") }
            current.device = target.device
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { throw .noInput }
        if current.sink == nil || current.format != format || current.ring !== ring {
            if let sink = current.sink { engine.detach(sink) }
            let sink = AVAudioSinkNode(receiverBlock: receiver(into: ring, rate: format.sampleRate))
            engine.attach(sink)
            engine.connect(engine.inputNode, to: sink, format: format)
            current.sink = sink; current.format = format; current.ring = ring
        }
        engine.prepare()
        do { try engine.start() } catch { throw .failed("the microphone did not start: \(error.localizedDescription)") }
        current.isOpen = true
        return (format.sampleRate, MicrophoneFollower.InUse(uid: target.uid, name: target.name, selection: plan.selection))
    }

    /// The open engine stopped by itself, as when its device goes away. A spurious notification (the engine posts
    /// some as it starts) finds it running and does nothing.
    private func engineMayHaveStopped() {
        end { state in state.engine.map { $0.isOpen && !$0.engine.isRunning } ?? false }
    }

    /// Ends the open engine's ring and tells the loss when `ending` says so.
    private func end(when ending: (inout State) -> Bool) {
        let ended: DictationAudioRing? = state.withLock { state in
            guard let current = state.engine, ending(&state) else { return nil }
            current.discard()
            state.engine = nil
            state.follower.closed()
            return current.ring
        }
        guard let ended else { return }
        ended.end()
        lost.withLock { $0 }?()
    }

    /// Listens, once, for changes that can move the input: the open microphone resolves again while capture is idle.
    private func watchRoute() {
        watching.withLock { token in
            guard token == nil else { return }
            token = MicrophoneWatch.shared.observe { [weak self] in self?.routeMayHaveChanged() }
        }
    }

    private func routeMayHaveChanged() {
        guard state.withLock({ $0.engine?.isOpen == true }) else { return }
        let idle = idle.withLock { $0 }
        Task { [weak self, changes] in
            let isIdle = await idle()
            changes.async { [weak self] in self?.checkRoute(captureIdle: isIdle) }
        }
    }

    /// Hex's poll: a change is noted whenever it is seen, and the input resolved again once capture is idle. A
    /// different input hands the source back through the loss; the same one is kept.
    private func checkRoute(captureIdle: Bool) {
        let generation = MicrophoneWatch.shared.generation
        let snapshot = MicrophoneDevices.snapshot(), selected = DictationAudioSettings.microphone()
        let route = snapshot.route(avoidBluetooth: DictationAudioSettings.avoidBluetooth())
        end { state in
            let now = ContinuousClock.now
            state.follower.requestSelection(selected, at: now)
            guard state.engine?.isOpen == true else { return false }
            if state.follower.poll(routeGeneration: generation, captureIdle: captureIdle, at: now) {
                let target = (try? Self.plan(selected: selected, snapshot, route)).flatMap { plan in snapshot.resolve(plan).map { (plan, $0) } }
                let found: MicrophoneFollower.Resolved = target.map { plan, input in
                    input.uid == state.follower.input?.uid ? .unchanged(plan.selection)
                        : .input(MicrophoneFollower.InUse(uid: input.uid, name: input.name, selection: plan.selection))
                } ?? .failed
                if state.follower.resolved(found, captureIdle: captureIdle, at: now) == .reopened { return true }
            }
            scheduleCheck(&state, now: now)
            return false
        }
    }

    /// Looks again while a check waits for an idle capture or a missing microphone's next look.
    private func scheduleCheck(_ state: inout State, now: ContinuousClock.Instant) {
        guard let next = state.follower.nextAttempt, !state.checkScheduled else { return }
        state.checkScheduled = true
        let wait = max(next - now, .milliseconds(250))
        changes.asyncAfter(deadline: .now() + .milliseconds(Int(wait / .milliseconds(1)))) { [weak self] in
            self?.state.withLock { $0.checkScheduled = false }
            self?.routeMayHaveChanged()
        }
    }

    /// The sink node's block. Runs on the real-time audio thread: everything it reads is captured up front.
    private static func receiver(into ring: DictationAudioRing, rate: Double) -> AVAudioSinkNodeReceiverBlock {
        let clock = CaptureInstant.HostClock()
        let nanosPerFrame = 1e9 / rate
        return { timestamp, frameCount, bufferList in
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            let start = clock.instant(ticks: timestamp.pointee.mHostTime)
            let through = start + .nanoseconds(Int64(Double(frames) * nanosPerFrame))
            if buffers.count == 1, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                // One buffer: mono, or interleaved channels.
                let channels = max(Int(buffers[0].mNumberChannels), 1)
                ring.write(frames: frames, capturedThrough: through) { frame in
                    var sum: Float = 0
                    for channel in 0 ..< channels { sum += data[frame * channels + channel] }
                    return sum / Float(channels)
                }
            } else if buffers.count > 1 {
                // One buffer per channel.
                let channels = buffers.count
                ring.write(frames: frames, capturedThrough: through) { frame in
                    var sum: Float = 0
                    for channel in 0 ..< channels { sum += buffers[channel].mData?.assumingMemoryBound(to: Float.self)[frame] ?? 0 }
                    return sum / Float(channels)
                }
            }
            return noErr
        }
    }
}
