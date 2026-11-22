import CoreGraphics
import Testing
@testable import OopsCore

struct WheelKeyRuleTests {
    private let chord = WheelChord(keyCode: 13, flags: [.maskControl, .maskCommand])

    private func key(_ code: Int64, _ flags: CGEventFlags = [], _ characters: String = "") -> WheelKey {
        WheelKey.classify(keyCode: code, flags: flags, characters: characters, chord: chord)
    }

    @Test func `arrows count with any modifiers`() {
        #expect(key(126) == .arrow(.up))
        #expect(key(124, [.maskCommand, .maskControl]) == .arrow(.right))
        #expect(key(125) == .arrow(.down))
        #expect(key(123, [.maskShift]) == .arrow(.left))
    }

    @Test func `the chord itself goes on, other shortcuts close the wheel`() {
        #expect(key(13, [.maskControl, .maskCommand], "w") == .pass)
        #expect(key(8, [.maskCommand], "c") == .leave)
        #expect(key(13, [.maskCommand], "w") == .leave)
        #expect(key(13, [.maskControl], "w") == .leave)
    }

    @Test func `escape, return and the erasing keys have their own meaning`() {
        #expect(key(53) == .escape)
        #expect(key(36) == .enter)
        #expect(key(76) == .enter)
        #expect(key(51) == .erase)
        #expect(key(117) == .erase)
    }

    @Test func `characters are text, including accented and dead ones`() {
        #expect(key(0, [], "a") == .text)
        #expect(key(14, [.maskAlternate], "é") == .text)
        #expect(key(33, [], "") == .text)
    }

    @Test func `space, tab and function keys are swallowed`() {
        #expect(key(49, [], " ") == .swallow)
        #expect(key(48, [], "\t") == .swallow)
        #expect(key(96, [], "\u{F708}") == .swallow)
        #expect(key(122, [], "") == .swallow)
    }

    @Test func `with no chord a shortcut key is just a key`() {
        #expect(WheelKey.classify(keyCode: 13, flags: [.maskCommand, .maskControl], characters: "w", chord: nil) == .leave)
    }

    @Test func `a shortcut that is a modified arrow passes, other arrows still count`() {
        let arrowChord = WheelChord(keyCode: 126, flags: [.maskControl, .maskCommand])
        func arrow(_ code: Int64, _ flags: CGEventFlags) -> WheelKey {
            WheelKey.classify(keyCode: code, flags: flags, characters: "", chord: arrowChord)
        }
        #expect(arrow(126, [.maskControl, .maskCommand]) == .pass)
        #expect(arrow(126, []) == .arrow(.up))
        #expect(arrow(126, [.maskCommand]) == .arrow(.up))
        #expect(arrow(124, [.maskControl, .maskCommand]) == .arrow(.right))
    }

    @Test func `fullwidth letters and emoji are text, function-key characters are not`() {
        #expect(key(0, [], "\u{FF41}") == .text)
        #expect(key(0, [], "\u{1F600}") == .text)
        #expect(key(0, [], "\u{F8FF}") == .swallow)
        #expect(key(126, [], "\u{F700}") == .arrow(.up))
        #expect(key(122, [], "\u{F704}") == .swallow)
    }

    @Test func `keypad clear is swallowed`() {
        #expect(key(71) == .swallow)
    }
}
