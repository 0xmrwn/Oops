import CoreGraphics
import Testing
@testable import OopsCore

struct WheelPiecesTests {
    private let frame = 1.0 / 120
    private let all: [ActionPlace] = [.up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft]

    private func rest(_ petals: [WheelPetal], reduceMotion: Bool = false, pills: [WheelPetal] = []) -> WheelMotion {
        var motion = WheelMotion(reduceMotion: reduceMotion)
        motion.open()
        motion.bloom(petals)
        if !pills.isEmpty { motion.bloomChoices(pills) }
        for _ in 0 ..< 240 { motion.step(frame) }
        return motion
    }

    private func width(_ pieces: [WheelPiece], _ id: String) -> Double { Double(pieces.first { $0.id == id }?.size.width ?? 0) }

    @Test func `a settled ring is fully visible`() {
        let motion = rest(WheelFixtures.petals(all))
        let petals = motion.pieces().filter { if case .petal = $0.kind { true } else { false } }
        #expect(petals.count == 8)
        #expect(petals.allSatisfy { $0.fade > 0.99 })
    }

    @Test func `a settled ring is fully visible with Reduce Motion too`() {
        let motion = rest(WheelFixtures.petals(all), reduceMotion: true)
        #expect(motion.pieces().filter { if case .petal = $0.kind { true } else { false } }.allSatisfy { $0.fade > 0.99 })
    }

    @Test func `choice pills are visible once out`() {
        let motion = rest(WheelFixtures.petals([.up]), pills: WheelFixtures.petals([.up, .down], symbol: nil))
        let pills = motion.pieces().filter { if case .pill = $0.kind { true } else { false } }
        #expect(pills.count == 2)
        #expect(pills.allSatisfy { $0.fade > 0.99 })
    }

    @Test func `a click on the hub during the stagger is the centre's`() {
        var motion = WheelMotion()
        motion.open()
        motion.bloom(WheelFixtures.petals(all))
        var checked = 0
        for _ in 0 ..< 24 {
            motion.step(frame)
            guard motion.pieces().contains(where: { $0.id == "centre" }) else { continue }
            checked += 1
            #expect(motion.hit(WheelLayout.hub) == .centre)
        }
        #expect(checked > 10)
    }

    @Test func `a petal on its way out is hit once it has left the centre`() {
        let motion = rest(WheelFixtures.petals(all))
        let up = motion.pieces().first { $0.id == motion.root.first { $0.petal.place == .up }?.id }
        #expect(motion.hit(up?.centre ?? .zero) == .place(.up))
    }

    @Test func `a long name is cut at the limit when it takes its place`() {
        func named(_ width: Double) -> WheelMotion {
            var motion = rest([WheelPetal(place: .right, title: "Name", symbol: "star", width: width)])
            motion.showNames()
            for _ in 0 ..< 120 { motion.step(frame) }
            return motion
        }
        let limit = named(WheelLayout.nameLimit).pieces(), long = named(5000).pieces()
        #expect(width(long, "r2-1") > 0)
        #expect(long.first { $0.id == "r2-1" } == limit.first { $0.id == "r2-1" })
    }

    @Test func `a long choice is cut at the limit too`() {
        func pill(_ width: Double) -> [WheelPiece] {
            rest(WheelFixtures.petals([.up]), pills: [WheelPetal(place: .right, title: "Name", symbol: nil, width: width)]).pieces()
        }
        #expect(width(pill(5000), "c2-1") == width(pill(WheelLayout.nameLimit), "c2-1"))
        #expect(width(pill(5000), "c2-1") > 0)
    }
}
