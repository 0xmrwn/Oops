import CoreGraphics
import Foundation
import Testing
@testable import OopsCore

/// The motion's timings were measured on a 120 Hz display; each range allows a frame of slack either side.
struct WheelMotionTests {
    private let frame = 1.0 / 120
    private let four: [ActionPlace] = [.up, .right, .down, .left]
    private let all: [ActionPlace] = [.up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft]

    private func settle(_ motion: inout WheelMotion) -> TimeInterval {
        var time = 0.0
        while !motion.settled, time < 3 {
            motion.step(frame)
            time += frame
        }
        return time
    }

    private func rest(_ places: [ActionPlace], reduceMotion: Bool = false) -> WheelMotion {
        var motion = WheelMotion(reduceMotion: reduceMotion)
        motion.open()
        motion.bloom(WheelFixtures.petals(places))
        _ = settle(&motion)
        for _ in 0 ..< 120 { motion.step(frame) }
        return motion
    }

    @Test func `four petals rest in the measured time`() {
        var motion = WheelMotion()
        motion.open()
        motion.bloom(WheelFixtures.petals(four))
        #expect((0.14 ... 0.19).contains(settle(&motion)))
    }

    @Test func `eight petals rest in the measured time`() {
        var motion = WheelMotion()
        motion.open()
        motion.bloom(WheelFixtures.petals(all))
        #expect((0.21 ... 0.26).contains(settle(&motion)))
    }

    @Test func `closing takes about 220 ms`() {
        var motion = rest(four)
        motion.close()
        var time = 0.0
        while !motion.gone, time < 2 {
            motion.step(frame)
            time += frame
        }
        #expect((0.19 ... 0.25).contains(time))
    }

    @Test func `cardinals leave first, then the diagonals`() {
        var motion = WheelMotion()
        motion.open()
        motion.bloom(WheelFixtures.petals(all))
        var launched: [(ActionPlace, TimeInterval)] = []
        var time = 0.0
        while launched.count < 8, time < 1 {
            motion.step(0.001)
            time += 0.001
            for node in motion.root where node.out.target == 1 && !launched.contains(where: { $0.0 == node.petal.place }) {
                launched.append((node.petal.place, time))
            }
        }
        #expect(launched.sorted { $0.1 < $1.1 }.map(\.0) == [.up, .right, .down, .left, .upRight, .downRight, .downLeft, .upLeft])
        #expect(launched.filter(\.0.isDiagonal).allSatisfy { $0.1 >= WheelLayout.wave - 0.002 })
    }

    @Test func `a neck shows only toward what is pointed at`() {
        var motion = rest(four)
        #expect(!motion.pieces().contains { if case .neck = $0.kind { true } else { false } })
        motion.setLive(.right)
        for _ in 0 ..< 24 { motion.step(frame) }
        let necks = motion.pieces().filter { if case .neck = $0.kind { true } else { false } }
        #expect(necks.count == 1)
        if case let .neck(angle, _, _, _) = necks.first?.kind { #expect(abs(angle) < 0.01) }
    }

    @Test func `reduce motion crossfades in place`() {
        var motion = WheelMotion(reduceMotion: true)
        motion.open()
        motion.bloom(WheelFixtures.petals(four))
        motion.step(frame)
        #expect(motion.root.allSatisfy { $0.out.x == 1 })
        var time = frame
        var necks = 0
        while time < 0.3 {
            motion.step(frame)
            time += frame
            necks += motion.pieces().filter { if case .neck = $0.kind { true } else { false } }.count
        }
        #expect(motion.root.allSatisfy { $0.fade.x > 0.95 })
        motion.setLive(.right)
        for _ in 0 ..< 24 { motion.step(frame) }
        necks += motion.pieces().filter { if case .neck = $0.kind { true } else { false } }.count
        #expect(necks == 0)
    }

    @Test func `names pull eight petals together`() {
        var motion = rest(all)
        #expect(motion.spacing > 10)
        motion.showNames()
        for _ in 0 ..< 60 { motion.step(frame) }
        #expect(abs(motion.spacing - 5) < 0.05)
    }

    @Test func `hit finds the petal under the point`() {
        let motion = rest(four)
        let right = motion.pieces().first { $0.id == motion.root.first { $0.petal.place == .right }?.id }
        #expect(motion.hit(right?.centre ?? .zero) == .place(.right))
        #expect(motion.hit(WheelLayout.hub) == .centre)
        #expect(motion.hit(CGPoint(x: 5, y: 5)) == nil)
    }

    @Test func `a chosen petal flows into the centre and the rest go back`() {
        var motion = rest(four)
        motion.select(.down, symbol: "star")
        #expect(motion.symbol == "star")
        #expect(motion.root.filter(\.chosen).map(\.petal.place) == [.down])
        #expect(!motion.root.map(\.leaving).contains(false))
        for _ in 0 ..< 60 { motion.step(frame) }
        #expect(motion.root.isEmpty)
    }

    @Test func `a second ring takes over the pointer`() {
        var motion = rest(four)
        motion.select(.right, symbol: "globe")
        for _ in 0 ..< 30 { motion.step(frame) }
        motion.bloomChoices(WheelFixtures.petals([.up, .down], symbol: nil))
        for _ in 0 ..< 60 { motion.step(frame) }
        motion.setLive(.up)
        #expect(motion.choice.first { $0.petal.place == .up }?.highlight.target == 1)
        #expect(motion.choice.first { $0.petal.place == .down }?.highlight.target == 0)
    }
}
