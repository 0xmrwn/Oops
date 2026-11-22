import CoreGraphics
import Foundation
@testable import Oops
import OopsCore
import Testing

/// The tap's own path, fed events as the system would: what it takes, what goes on, and how long it stays.
@MainActor struct WheelKeysTests {
    private static let dictate = WheelChord(keyCode: 2, flags: .maskAlternate)

    private static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], characters: String = "", repeating: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        let units = Array(characters.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        if repeating { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }

    /// Waits for `condition`, a few seconds at most: under a loaded test run the main actor can be late.
    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func `another Oops shortcut goes on even when it types`() throws {
        let heard = Box(0)
        let keys = try WheelKeys(chords: [Self.dictate], deliver: { _ in heard.value += 1; return false }, listening: false)
        #expect(!keys.handle(.keyDown, Self.key(2, down: true, flags: .maskAlternate, characters: "∂")))
        #expect(!keys.handle(.keyUp, Self.key(2, down: false, flags: .maskAlternate, characters: "∂")))
        #expect(heard.value == 0, "the wheel never hears it: its own handler closes the wheel")
        // The same key without its modifier is typing, which the wheel keeps from the draft.
        #expect(keys.handle(.keyDown, Self.key(2, down: true, characters: "d")))
    }

    @Test func `a key held past the drain still never reaches the draft`() async throws {
        let held = Box(true)
        let keys = try WheelKeys(chords: [], deliver: { _ in false }, listening: false, keyIsDown: { _ in held.value },
                                 drain: .init(first: .milliseconds(20), poll: .milliseconds(10), limit: .seconds(5)))
        #expect(keys.handle(.keyDown, Self.key(0, down: true, characters: "a")))
        keys.drain()
        try await Task.sleep(for: .milliseconds(120))
        #expect(keys.isLive, "the key is still held")
        #expect(keys.handle(.keyDown, Self.key(0, down: true, characters: "a", repeating: true)), "its repeats stop here")
        held.value = false
        await Self.until { !keys.isLive }
        #expect(!keys.isLive, "let go, even with its key-up missed, the tap goes")
        #expect(!keys.handle(.keyDown, Self.key(0, down: true, characters: "a")))
    }

    @Test func `keys wait while the field comes up, then go to it`() throws {
        let posted = Box<[String]>([])
        let keys = try WheelKeys(chords: [Self.dictate], deliver: { _ in false }, listening: false, post: { event in
            var length = 0
            var units = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
            posted.value.append((event.type == .keyDown ? "down " : "up ") + String(utf16CodeUnits: units, count: length))
        })
        #expect(keys.handle(.keyDown, Self.key(0, down: true, characters: "a")))
        keys.hold()
        #expect(keys.handle(.keyDown, Self.key(11, down: true, characters: "b")))
        #expect(keys.handle(.keyUp, Self.key(11, down: false, characters: "b")))
        #expect(!keys.handle(.keyDown, Self.key(2, down: true, flags: .maskAlternate, characters: "∂")), "Oops's shortcuts still go on")
        #expect(posted.value.isEmpty)
        keys.replay()
        #expect(keys.mode == .typing)
        #expect(posted.value == ["down b", "up b"])
        #expect(!keys.handle(.keyDown, Self.key(8, down: true, characters: "c")), "the field has the keys now")
        #expect(!keys.handle(.keyUp, Self.key(8, down: false, characters: "c")))
    }

    @Test func `the key that opens the field is held as its first character, a Return is not`() throws {
        let posted = Box(0)
        let keys = Box<WheelKeys?>(nil)
        keys.value = try WheelKeys(chords: [], deliver: { input in
            // The controller opens the field on the first text or Return it hears.
            if case .key(.text, true, _) = input { keys.value?.hold() }
            if case .key(.enter, true, _) = input { keys.value?.hold() }
            return false
        }, listening: false, post: { _ in posted.value += 1 })
        let tap = try #require(keys.value)
        #expect(tap.handle(.keyDown, Self.key(36, down: true)))
        tap.replay()
        #expect(posted.value == 0, "Return only opened the field")
        #expect(tap.handle(.keyUp, Self.key(36, down: false)), "its key-up still stops here")

        posted.value = 0
        keys.value = try WheelKeys(chords: [], deliver: { input in
            if case .key(.text, true, _) = input { keys.value?.hold() }
            return false
        }, listening: false, post: { _ in posted.value += 1 })
        let second = try #require(keys.value)
        #expect(second.handle(.keyDown, Self.key(0, down: true, characters: "q")))
        second.replay()
        #expect(posted.value == 1, "the first character reaches the field")
        #expect(!second.handle(.keyUp, Self.key(0, down: false, characters: "q")), "and its key-up goes there too")
    }

    @Test func `Escape closes at once while the field is still coming up`() throws {
        let heard = Box(0)
        let keys = try WheelKeys(chords: [], deliver: { input in
            if case .key(.escape, true, _) = input { heard.value += 1 }
            return false
        }, listening: false, post: { _ in Issue.record("nothing waits to be posted") })
        keys.hold()
        #expect(keys.handle(.keyDown, Self.key(53, down: true)))
        #expect(heard.value == 1)
        keys.replay()
    }

    @Test func `a field that never took the keys drops them`() throws {
        let posted = Box(0)
        let keys = try WheelKeys(chords: [], deliver: { _ in false }, listening: false, post: { _ in posted.value += 1 })
        keys.hold()
        #expect(keys.handle(.keyDown, Self.key(0, down: true, characters: "a")))
        keys.discardHeld()
        keys.replay()
        #expect(posted.value == 0)
        #expect(keys.mode == .wheel)
    }

    @Test func `draining ends at the key-up`() throws {
        let keys = try WheelKeys(chords: [], deliver: { _ in false }, listening: false, keyIsDown: { _ in true })
        #expect(keys.handle(.keyDown, Self.key(125, down: true)))
        keys.drain()
        #expect(keys.isLive)
        #expect(keys.handle(.keyUp, Self.key(125, down: false)))
        #expect(!keys.isLive)
    }

    @Test func `a key held forever still lets the tap go at the limit`() async throws {
        let keys = try WheelKeys(chords: [], deliver: { _ in false }, listening: false, keyIsDown: { _ in true },
                                 drain: .init(first: .milliseconds(10), poll: .milliseconds(10), limit: .milliseconds(60)))
        #expect(keys.handle(.keyDown, Self.key(0, down: true, characters: "a")))
        keys.drain()
        await Self.until { !keys.isLive }
        #expect(!keys.isLive)
    }
}

@MainActor private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
