import Testing
@testable import OopsCore

struct WheelGestureTests {
    private let starters = WheelFixtures.places
    private let eight = Set(WheelFixtures.eight.actions.map(\.place))

    @Test func `one arrow points at its place`() {
        var gesture = WheelGesture()
        gesture.press(.right, among: starters)
        #expect(gesture.pointed == .right)
    }

    @Test func `adjacent arrows make the diagonal`() {
        var gesture = WheelGesture()
        gesture.press(.up, among: eight)
        gesture.press(.right, among: eight)
        #expect(gesture.pointed == .upRight)
    }

    @Test func `a diagonal with no action falls to the later arrow`() {
        var gesture = WheelGesture()
        gesture.press(.up, among: starters)
        gesture.press(.right, among: starters)
        #expect(gesture.pointed == .right)
        var other = WheelGesture()
        other.press(.right, among: starters)
        other.press(.up, among: starters)
        #expect(other.pointed == .up)
    }

    @Test func `opposite arrows are neutral`() {
        var gesture = WheelGesture()
        gesture.press(.up, among: starters)
        gesture.press(.down, among: starters)
        #expect(gesture.pointed == nil)
        gesture.press(.left, among: starters)
        #expect(gesture.pointed == .left)
        gesture.press(.right, among: starters)
        #expect(gesture.pointed == nil)
    }

    @Test func `an empty place points at nothing`() {
        var gesture = WheelGesture()
        gesture.press(.left, among: starters.subtracting([.left]))
        #expect(gesture.pointed == nil)
    }

    @Test func `the first key-up commits after the grace`() {
        var gesture = WheelGesture()
        gesture.press(.right, among: starters)
        gesture.release(.right, at: 0.20)
        #expect(gesture.commitAt == 0.25)
        #expect(gesture.commit(at: 0.249, among: starters) == nil)
        #expect(gesture.commit(at: 0.25, among: starters) == .some(.right))
        #expect(gesture.held.isEmpty)
    }

    @Test func `a second key-up inside the grace is the same gesture`() {
        var gesture = WheelGesture()
        gesture.press(.up, among: eight)
        gesture.press(.right, among: eight)
        gesture.release(.up, at: 0.30)
        gesture.release(.right, at: 0.33)
        #expect(gesture.commit(at: 0.35, among: eight) == .some(.upRight))
    }

    @Test func `a key-up after the grace is ignored`() {
        var gesture = WheelGesture()
        gesture.press(.up, among: eight)
        gesture.press(.right, among: eight)
        gesture.release(.up, at: 0.30)
        #expect(gesture.commit(at: 0.35, among: eight) == .some(.upRight))
        gesture.release(.right, at: 0.40)
        #expect(gesture.commitAt == nil)
    }

    @Test func `a press inside the grace cancels the commit`() {
        var gesture = WheelGesture()
        gesture.press(.right, among: starters)
        gesture.release(.right, at: 0.20)
        gesture.press(.down, among: starters)
        #expect(gesture.commitAt == nil)
        #expect(gesture.pointed == .down)
    }

    @Test func `letting go from neutral runs nothing`() {
        var gesture = WheelGesture()
        gesture.press(.up, among: starters)
        gesture.press(.down, among: starters)
        gesture.release(.up, at: 0.30)
        gesture.release(.down, at: 0.31)
        #expect(gesture.commit(at: 0.36, among: starters) == .some(nil))
    }

    @Test func `hover is ignored while arrows are held`() {
        var gesture = WheelGesture()
        gesture.press(.right, among: starters)
        gesture.point(.down)
        #expect(gesture.pointed == .right)
    }

    @Test func `arrows come from their key codes`() {
        #expect([126, 124, 125, 123].compactMap { WheelArrow(keyCode: $0) } == [.up, .right, .down, .left])
        #expect(WheelArrow(keyCode: 0) == nil)
    }

    @Test func `hover is ignored while a release is about to commit`() {
        var gesture = WheelGesture()
        gesture.press(.right, among: starters)
        gesture.release(.right, at: 0.20)
        gesture.point(.down)
        #expect(gesture.pointed == .right)
        #expect(gesture.commit(at: 0.25, among: starters) == .some(.right))
        gesture.point(.down)
        #expect(gesture.pointed == .down)
    }
}
