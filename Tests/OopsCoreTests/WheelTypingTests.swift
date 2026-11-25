import Foundation
import Testing
@testable import OopsCore

/// The typed centre: where it is offered, what it says, and what Return runs.
struct WheelTypingTests {
    private let translate = WheelFixtures.action("Translate")
    /// The number of lines in `WheelTyping.unavailable`.
    private static let listed = 0

    private func typingWheel(_ library: ActionLibrary = WheelFixtures.starters) -> Wheel {
        var wheel = Wheel()
        _ = wheel.open(library, restorable: nil, typing: true, at: 0)
        _ = wheel.placed(at: 0.03)
        return wheel
    }

    @Test func `an app on the list can't type`() {
        #expect(!WheelTyping.isAvailable(bundleID: "a.b", unavailable: ["a.b"]))
        #expect(WheelTyping.isAvailable(bundleID: "c.d", unavailable: ["a.b"]))
        #expect(WheelTyping.isAvailable(bundleID: nil, unavailable: ["a.b"]))
    }

    @Test func `the list is well formed`() {
        for bundle in WheelTyping.unavailable {
            #expect(!bundle.isEmpty && bundle.contains(".") && !bundle.contains { $0.isWhitespace }, "\(bundle)")
        }
        // As many entries as the source lists: a line written twice would hide one app.
        #expect(WheelTyping.unavailable.count == Self.listed)
    }

    @Test func `the hint names what to type`() {
        #expect(WheelTyping.hint(at: .root) == "Type an instruction")
        #expect(WheelTyping.hint(at: .choices(translate)) == "Language")
        #expect(WheelTyping.hint(at: .closed) == nil)
    }

    @Test func `typing at the first ring opens the field`() {
        var wheel = typingWheel()
        #expect(wheel.type(at: 0.5) == [.beginTyping(placeholder: "Type an instruction")])
        #expect(wheel.level == .typing(from: .root))
        #expect(wheel.isOpen)
    }

    @Test func `typing at a ring asks for a value`() {
        var wheel = typingWheel()
        _ = WheelFixtures.tap(&wheel, .right, at: 0.3)
        #expect(wheel.type(at: 0.5) == [.beginTyping(placeholder: "Language")])
        #expect(wheel.level == .typing(from: .choices(translate)))
    }

    @Test func `Return on words runs them`() {
        var wheel = typingWheel()
        _ = wheel.type(at: 0.5)
        #expect(wheel.submit("make it formal") == [.run(.typed("make it formal")), .close])
        #expect(!wheel.isOpen)
    }

    @Test func `a value typed at a ring runs the action with it`() {
        var wheel = typingWheel()
        _ = WheelFixtures.tap(&wheel, .right, at: 0.3)
        _ = wheel.type(at: 0.5)
        #expect(wheel.submit(" Klingon ") == [.run(.saved(translate, value: "Klingon")), .close])
    }

    @Test func `Return on nothing does nothing`() {
        var wheel = typingWheel()
        _ = wheel.type(at: 0.5)
        #expect(wheel.submit("  ").isEmpty)
        #expect(wheel.level == .typing(from: .root))
    }

    @Test func `typing waits for the arrows`() {
        var wheel = typingWheel()
        _ = wheel.press(.right, at: 0.3)
        #expect(wheel.type(at: 0.35).isEmpty)
        _ = wheel.release(.right, at: 0.4)
        #expect(wheel.type(at: 0.42).isEmpty, "a release about to commit wins")
    }

    @Test func `an app that can't type ignores typing`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.type(at: 0.5).isEmpty)
        #expect(wheel.clickCentre(at: 0.5).isEmpty)
        #expect(wheel.level == .root)
    }

    @Test func `a click on the centre opens the field`() {
        var wheel = typingWheel()
        #expect(wheel.clickCentre(at: 0.5) == [.beginTyping(placeholder: "Type an instruction")])
    }

    @Test func `while typing the arrows and the pointer do nothing`() {
        var wheel = typingWheel()
        _ = wheel.type(at: 0.5)
        #expect(wheel.press(.down, at: 0.6).isEmpty)
        #expect(wheel.hover(.down, at: 0.6).isEmpty)
        #expect(wheel.click(.down, at: 0.6).isEmpty)
        #expect(wheel.advance(to: 3).isEmpty)
        #expect(wheel.nextDue == nil)
    }

    @Test func `a field that never took the keys goes back to the ring`() {
        var wheel = typingWheel()
        _ = wheel.type(at: 0.5)
        #expect(wheel.typingFailed(at: 0.8) == [.bloom([.up, .right, .down, .left])])
        #expect(wheel.level == .root)

        var ring = typingWheel()
        _ = WheelFixtures.tap(&ring, .right, at: 0.3)
        _ = ring.type(at: 0.5)
        #expect(ring.typingFailed(at: 0.8) == [.bloomChoices([.up, .right, .down, .left])])
        #expect(ring.level == .choices(translate))
    }

    @Test func `the hint waits for the linger at a ring, and the first ring leaves it to its cue`() {
        var wheel = typingWheel()
        let effects = wheel.advance(to: 0.7)
        #expect(effects == [.showNames])
        _ = WheelFixtures.tap(&wheel, .right, at: 1.0)
        #expect(wheel.advance(to: 1.17) == [.bloomChoices([.up, .right, .down, .left])])
        #expect(!wheel.advance(to: 1.86).contains(.showHint))
        #expect(wheel.advance(to: 1.87) == [.showHint])
    }

    @Test func `no hint where the centre can't type`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.advance(to: 0.7) == [.showNames])
    }

    @Test func `the announcements say the centre takes typing`() {
        let petals = [WheelPetal(place: .up, title: "Shorten", symbol: nil, width: 50)]
        #expect(WheelAnnouncement.opening(petals, typing: true) == "Actions. Up: Shorten. Or type an instruction.")
        #expect(WheelAnnouncement.opening([], typing: true) == "Actions. None saved yet. Or type an instruction.")
        #expect(WheelAnnouncement.choices("Language", petals, typing: true) == "Language. Up: Shorten. Or type one.")
        #expect(WheelAnnouncement.opening(petals) == "Actions. Up: Shorten.")
    }
}
