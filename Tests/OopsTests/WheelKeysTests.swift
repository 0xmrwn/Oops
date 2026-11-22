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
