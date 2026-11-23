import AppKit
import OopsCore

/// Return and Escape for an agent run's ready drop at the caret, through a session event tap that exists only while
/// that drop is up, as the wheel's keys do. Each press is put to `takes` as it arrives: one it takes stops here, with
/// its release, and goes to `pressed`; every other key event goes on untouched, so nothing is ever posted again.
@MainActor final class AgentReadyKeys {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let takes: (AgentReadyKey) -> Bool
    private let pressed: (AgentReadyKey) -> Void
    /// Key codes whose press stopped here: their release stops too, even once the drop has gone.
    private var taken: Set<Int64> = []
    private var stopping = false

    /// Nil when no tap can be made (no Accessibility): the keys stay the app's, and a click still puts the answer in.
    init?(takes: @escaping (AgentReadyKey) -> Bool, pressed: @escaping (AgentReadyKey) -> Void) {
        self.takes = takes; self.pressed = pressed
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, context in
                                    guard let context else { return Unmanaged.passUnretained(event) }
                                    // The source is on the main run loop, so this runs on the main thread.
                                    let stop = MainActor.assumeIsolated {
                                        Unmanaged<AgentReadyKeys>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                                    }
                                    return stop ? nil : Unmanaged.passUnretained(event)
                                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return nil }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    isolated deinit { remove() }

    /// True when the event stops here.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, !stopping { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            guard taken.remove(code) != nil else { return false }
            if stopping, taken.isEmpty { remove() }
            return true
        }
        guard type == .keyDown, !stopping,
              let key = AgentReadyKey(keyCode: code, modifiers: !event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskShift]),
                                      repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0),
              takes(key) else { return false }
        taken.insert(code)
        // After the tap has answered, so the run's change of state doesn't hold the event up.
        Task { [pressed] in pressed(key) }
        return true
    }

    /// The drop has gone: the tap goes, once a key it took has come up, or after a second at most. It keeps itself
    /// until then.
    func stop() {
        stopping = true
        guard !taken.isEmpty else { return remove() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in remove() }
    }

    private func remove() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; taken = []
    }
}
