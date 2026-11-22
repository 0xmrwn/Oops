import Testing
@testable import OopsCore

struct WheelTests {
    private let starters = WheelFixtures.starters
    private let eight = WheelFixtures.eight
    private let shorten = WheelFixtures.action("Shorten")
    private let translate = WheelFixtures.action("Translate")

    @Test func `opening blooms once placed, in place order`() {
        var wheel = Wheel()
        #expect(wheel.open(starters, restorable: nil, at: 0).isEmpty)
        #expect(wheel.placed(at: 0.03) == [.bloom([.up, .right, .down, .left])])
    }

    @Test func `diagonals bloom after the cardinals`() {
        var wheel = Wheel()
        _ = wheel.open(eight, restorable: nil, at: 0)
        #expect(wheel.placed(at: 0.03) == [.bloom([.up, .right, .down, .left, .upRight, .downLeft])])
    }

    @Test func `names come after lingering 700 ms`() {
        var wheel = WheelFixtures.opened()
        #expect(!wheel.advance(to: 0.69).contains(.showNames))
        #expect(wheel.advance(to: 0.70).contains(.showNames))
    }

    @Test func `pointing holds the names back`() {
        var wheel = WheelFixtures.opened()
        _ = wheel.press(.right, at: 0.3)
        #expect(!wheel.advance(to: 0.9).contains(.showNames))
    }

    @Test func `leaving a hovered petal restarts the linger`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.hover(.right, at: 0.3) == [.point(.right)])
        #expect(wheel.hover(nil, at: 0.5) == [.point(nil)])
        #expect(!wheel.advance(to: 1.19).contains(.showNames))
        #expect(wheel.advance(to: 1.2).contains(.showNames))
    }

    @Test func `an early arrow skips the bloom`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.press(.down, at: 0.10).contains(.skipBloom))
        _ = wheel.release(.down, at: 0.12)
        let effects = wheel.advance(to: 0.17)
        #expect(effects == [.select(.down, symbol: shorten.symbol), .run(.saved(shorten, value: nil)), .close])
        #expect(wheel.advance(to: 0.5).isEmpty)
    }

    @Test func `an early arrow still held blooms with it pointed`() {
        var wheel = Wheel()
        _ = wheel.open(starters, restorable: nil, at: 0)
        _ = wheel.press(.right, at: 0.05)
        #expect(wheel.placed(at: 0.08).isEmpty)
        let effects = wheel.advance(to: 0.17)
        #expect(effects.contains(.bloom([.up, .right, .down, .left])))
        #expect(effects.contains(.point(.right)))
    }

    @Test func `a later arrow keeps the bloom`() {
        var wheel = WheelFixtures.opened()
        #expect(!wheel.press(.right, at: 0.2).contains(.skipBloom))
    }

    @Test func `an arrow before the window is up and after the flick points once it blooms`() {
        var wheel = Wheel()
        _ = wheel.open(starters, restorable: nil, at: 0)
        #expect(wheel.press(.right, at: 0.2) == [.point(.right)])
        #expect(wheel.placed(at: 0.25) == [.bloom([.up, .right, .down, .left]), .point(.right)])
    }

    @Test func `an action with a choice opens its ring`() {
        var wheel = WheelFixtures.opened()
        #expect(WheelFixtures.tap(&wheel, .right, at: 0.3) == [.select(.right, symbol: "globe")])
        #expect(wheel.level == .choices(translate))
        #expect(wheel.advance(to: 0.47) == [.bloomChoices([.up, .right, .down, .left])])
    }

    @Test func `a value runs the action with it`() {
        var wheel = WheelFixtures.opened()
        _ = WheelFixtures.tap(&wheel, .right, at: 0.3)
        _ = wheel.advance(to: 0.5)
        let effects = WheelFixtures.tap(&wheel, .up, at: 0.6)
        #expect(effects == [.select(.up, symbol: "globe"), .run(.saved(translate, value: "French")), .close])
        #expect(wheel.level == .closed)
    }

    @Test func `an empty place in the ring does nothing`() {
        var wheel = WheelFixtures.opened()
        _ = WheelFixtures.tap(&wheel, .up, at: 0.3)
        _ = wheel.advance(to: 0.5)
        #expect(WheelFixtures.tap(&wheel, .left, at: 0.6).isEmpty)
        #expect(wheel.level == .choices(WheelFixtures.action("Sharpen prompt")))
    }

    @Test func `a choice with no values opens an empty ring`() {
        let empty = Action(symbol: "star", name: "X", instruction: "Do X " + Action.choiceMark, choice: ActionChoice(name: "X", values: [:]), place: .up)
        var wheel = WheelFixtures.opened(ActionLibrary(actions: [empty]))
        _ = WheelFixtures.tap(&wheel, .up, at: 0.3)
        #expect(wheel.level == .choices(empty))
        #expect(wheel.advance(to: 0.5) == [.bloomChoices([])])
    }

    @Test func `the same direction restores inside the window`() {
        var wheel = WheelFixtures.opened(restorable: shorten.id)
        #expect(WheelFixtures.tap(&wheel, .down, at: 0.3) == [.select(.down, symbol: "arrow.uturn.backward"), .restore, .close])
    }

    @Test func `a choice's direction restores without its ring`() {
        var wheel = WheelFixtures.opened(restorable: translate.id)
        let effects = WheelFixtures.tap(&wheel, .right, at: 0.3)
        #expect(effects.contains(.restore))
        #expect(!effects.contains(.select(.right, symbol: "globe")))
        #expect(wheel.level == .closed)
    }

    @Test func `another direction runs while one is restorable`() {
        var wheel = WheelFixtures.opened(restorable: shorten.id)
        _ = WheelFixtures.tap(&wheel, .left, at: 0.3)
        #expect(wheel.level == .choices(WheelFixtures.action("Tone")))
    }

    @Test func `after the window the direction runs again`() {
        var wheel = WheelFixtures.opened(restorable: nil)
        #expect(WheelFixtures.tap(&wheel, .down, at: 0.3).contains(.run(.saved(shorten, value: nil))))
    }

    @Test func `zero actions show only the centre`() {
        var wheel = Wheel()
        _ = wheel.open(ActionLibrary(actions: []), restorable: nil, at: 0)
        #expect(wheel.placed(at: 0.03) == [.bloom([])])
        #expect(WheelFixtures.tap(&wheel, .up, at: 0.3).isEmpty)
        #expect(wheel.click(.up, at: 0.5).isEmpty)
    }

    @Test func `a click runs at once`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.click(.down, at: 0.5) == [.select(.down, symbol: shorten.symbol), .run(.saved(shorten, value: nil)), .close])
    }

    @Test func `a click on an empty place does nothing`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.click(.upRight, at: 0.5).isEmpty)
        #expect(wheel.level == .root)
    }

    @Test func `closing ends everything`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.close() == [.close])
        #expect(wheel.level == .closed)
        #expect(wheel.press(.up, at: 0.4).isEmpty)
        #expect(wheel.close().isEmpty)
    }

    @Test func `a held arrow past the flick points without running`() {
        var wheel = WheelFixtures.opened()
        #expect(wheel.press(.right, at: 0.5) == [.point(.right)])
        #expect(wheel.advance(to: 0.9).isEmpty)
        #expect(wheel.level == .root)
    }

    @Test func `a release is honoured before a press that comes after its grace`() {
        func run(advancing: Bool) -> [WheelEffect] {
            var wheel = WheelFixtures.opened()
            var effects = wheel.press(.down, at: 0.19)
            effects += wheel.release(.down, at: 0.200)
            if advancing { effects += wheel.advance(to: 0.250) }
            effects += wheel.press(.left, at: 0.252)
            return effects
        }
        let direct = run(advancing: false)
        #expect(direct.contains(.run(.saved(shorten, value: nil))))
        #expect(direct == run(advancing: true))
    }

    @Test func `a press inside the grace still cancels the release`() {
        var wheel = WheelFixtures.opened()
        _ = wheel.press(.down, at: 0.19)
        _ = wheel.release(.down, at: 0.200)
        #expect(wheel.press(.left, at: 0.240) == [.point(.left)])
        #expect(wheel.advance(to: 0.260).isEmpty)
    }

    @Test func `hover does not move the highlight while a release is about to commit`() {
        var wheel = WheelFixtures.opened()
        _ = wheel.press(.right, at: 0.3)
        _ = wheel.release(.right, at: 0.35)
        #expect(wheel.hover(.down, at: 0.37).isEmpty)
        #expect(wheel.advance(to: 0.40) == [.select(.right, symbol: translate.symbol)])
    }

    @Test func `an early arrow on a ring already out leaves its petals alone`() {
        var wheel = WheelFixtures.opened()
        _ = WheelFixtures.tap(&wheel, .right, at: 0.3)
        #expect(wheel.advance(to: 0.47) == [.bloomChoices([.up, .right, .down, .left])])
        #expect(!wheel.press(.up, at: 0.50).contains(.skipBloom))
        #expect(!wheel.advance(to: 0.7).contains(.bloomChoices([.up, .right, .down, .left])))
    }

    @Test func `an early arrow on a ring not out yet holds its bloom back`() {
        var wheel = WheelFixtures.opened()
        _ = WheelFixtures.tap(&wheel, .right, at: 0.3)
        #expect(wheel.press(.up, at: 0.45).contains(.skipBloom))
    }
}
