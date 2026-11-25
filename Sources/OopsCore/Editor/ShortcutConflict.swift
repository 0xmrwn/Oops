import Foundation

/// Whether another app took a chord while a shortcut records. A hotkey or event tap of another app takes the
/// key-down before it reaches Oops, so the recorder hears nothing; the keyboard state still shows the key down.
/// Sampled while recording: a key that goes down with ⌃, ⌥ or ⌘ and whose key-down doesn't reach the recorder
/// within `window` was taken, and the chord seen is reported once for that press.
public struct ShortcutConflict: Sendable {
    /// A chord as the keyboard state showed it: a key code and Carbon modifiers.
    public struct Chord: Equatable, Sendable {
        public let keyCode: UInt16
        public let modifiers: UInt32
        public init(keyCode: UInt16, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    }

    public static var interval: Duration { .milliseconds(30) }
    /// Far longer than a key-down takes from the keyboard state to the recorder, far shorter than a press.
    public static var window: Duration { .milliseconds(250) }
    /// ⌘, ⇧, ⇪, ⌥ and ⌃ on both sides, and fn: never a chord's key.
    public static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    /// Carbon's ⌘, ⌥ and ⌃: a shortcut needs one (`ShortcutCapture`).
    static let required: UInt32 = 0x0100 | 0x0800 | 0x1000

    /// Keys down before recording began, which a remapper can leave set: ignored until they come up.
    private var stale: Set<UInt16>
    /// Keys whose press is settled (heard, reported, or not a shortcut) until they come up.
    private var settled: Set<UInt16> = []
    /// Presses waiting for their key-down, oldest first. Each keeps the modifiers of its first down sample: a
    /// modifier added later, or a second press of the same key, never joins it.
    private var pending: [Press] = []

    private struct Press {
        let key: UInt16
        let seen: ContinuousClock.Instant
        let modifiers: UInt32
        /// The key has come up since: seen down again, it is a new press.
        var up = false
    }

    public init(alreadyDown: Set<UInt16>) { stale = alreadyDown }

    /// The recorder heard a key-down of this key: the oldest press of it waiting reached Oops. A repeat
    /// acknowledges nothing: it can reach Oops after another app took the press itself.
    public mutating func heard(_ keyCode: UInt16, isRepeat: Bool) {
        guard !isRepeat else { return }
        if let index = pending.firstIndex(where: { $0.key == keyCode }) { pending.remove(at: index) }
        if !pending.contains(where: { $0.key == keyCode && !$0.up }) { settled.insert(keyCode) }
    }

    /// One sample of the keys down and the modifiers held. Returns a chord another app took, at most one per press.
    public mutating func sample(down keys: Set<UInt16>, modifiers: UInt32, at now: ContinuousClock.Instant) -> Chord? {
        stale.formIntersection(keys)
        settled.formIntersection(keys)
        for index in pending.indices where !keys.contains(pending[index].key) { pending[index].up = true }
        for key in keys.subtracting(stale).subtracting(Self.modifierKeys).subtracting(settled).sorted() {
            guard !pending.contains(where: { $0.key == key && !$0.up }) else { continue }
            if modifiers & Self.required != 0 { pending.append(Press(key: key, seen: now, modifiers: modifiers)) } else { settled.insert(key) }
        }
        guard let index = pending.firstIndex(where: { $0.seen.duration(to: now) >= Self.window }) else { return nil }
        let press = pending.remove(at: index)
        if !press.up, !pending.contains(where: { $0.key == press.key }) { settled.insert(press.key) }
        return Chord(keyCode: press.key, modifiers: press.modifiers)
    }
}
