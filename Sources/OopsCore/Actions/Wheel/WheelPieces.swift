import CoreGraphics
import Foundation

public enum WheelHit: Equatable, Sendable { case place(ActionPlace), centre }

/// One piece of glass for this frame. Everything is in canvas points, top-left origin.
public struct WheelPiece: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case centre
        case petal(symbol: String, title: String, reveal: Double, side: Int)
        case pill(title: String)
        /// A short liquid bridge from the centre to what is pointed at.
        case neck(angle: Double, length: Double, end: Double, waist: Double)
    }

    public let id: String
    public var centre: CGPoint, size: CGSize
    /// How much of the feathered middle to cut out of the glass.
    public var hole: Double
    public var kind: Kind
    public var scale: Double, fade: Double
    public var light: Double, words: Double, lens: Double

    public init(id: String, centre: CGPoint, size: CGSize, hole: Double, kind: Kind, scale: Double, fade: Double,
                light: Double = 0, words: Double = 0, lens: Double = 0) {
        self.id = id
        self.centre = centre
        self.size = size
        self.hole = hole
        self.kind = kind
        self.scale = scale
        self.fade = fade
        self.light = light
        self.words = words
        self.lens = lens
    }
}

public extension WheelMotion {
    /// A diagonal is filled: the petals rest closer together and the ones on the vertical lift to make room for words.
    var crowded: Bool { root.contains { $0.petal.place.isDiagonal } }

    /// 1 while anything is still travelling.
    var travel: Double { min(1, ((root + choice).map { abs($0.out.x - $0.out.target) }.max() ?? 0) * 4) }

    /// The merge distance is for travel: it is what draws the necks. Eight petals rest closer together than that,
    /// and named ones closer still, so it comes down once they have arrived and drops at once when words are due.
    var spacing: Double {
        guard crowded else { return WheelLayout.merge }
        let staying = root.filter { !$0.leaving }
        let shown = min(1, (root.map { max($0.name.x, $0.highlight.x) }.max() ?? 0) * 4)
        let words = max(shown, named || staying.contains { $0.highlight.target > 0 } ? 1 : 0)
        let rest = min(WheelLayout.merge, 16)
        let open = rest + (min(WheelLayout.merge, WheelLayout.merge8) - rest) * travel
        return open + (5 - open) * words
    }

    var centreScale: Double { reduceMotion ? 1 : (0.35 + 0.65 * present.x) * dip.x }
    var centreSize: CGSize { CGSize(width: max(WheelLayout.drop, width.x) * centreScale, height: WheelLayout.drop * centreScale) }
    var centrePoint: CGPoint { CGPoint(x: WheelLayout.hub.x + recoilX.x, y: WheelLayout.hub.y + recoilY.x) }

    func pieces() -> [WheelPiece] {
        var list: [WheelPiece] = []
        let hub = WheelLayout.hub, radius = WheelLayout.radius, petal = WheelLayout.petal
        let quiet = 1 - 0.5 * dim.x
        for node in root {
            let place = node.petal.place
            let grown = max(0.04, node.grow.x), lit = max(0, node.highlight.x)
            let reveal = min(1.15, max(0, max(node.highlight.x, node.name.x)))
            // Pointed at, a petal grows; the others step back a little.
            let others = node.leaving ? 1 : 1 - 0.1 * dim.x * (1 - min(1, lit))
            let size = petal * grown * (1 + 0.18 * lit) * others
            let extra = (Self.label(node.petal.width) + 17) * reveal
            let way = WheelLayout.unit(place)
            let side = way.x > 0.3 ? 1 : way.x < -0.3 ? -1 : 0
            let lift = side == 0 ? (crowded ? 22.0 : 6.0) * reveal : 0
            let reach = radius * node.out.x - 3 * min(1, lit)
            let centre = CGPoint(x: hub.x + way.x * reach + Double(side) * extra / 2, y: hub.y + way.y * reach + way.y * lift)
            if !node.leaving, node.out.x > 0.85, let bridge = neck(node.id, place, to: reach + abs(way.y) * lift - size / 2, lit: lit) { list.append(bridge) }
            // The icon shows only once its petal is clear of the centre's eyes.
            let arrived = max(0, min(1, (node.out.x - 0.3) / 0.45))
            let standing = node.leaving ? max(0, min(1, node.grow.x * 1.4)) : (place == live ? 1 : quiet)
            let formed = max(0, min(1, (node.out.x - 0.72) / 0.25)) * max(0, min(1, grown * 2 - 1))
            list.append(WheelPiece(id: node.id, centre: centre, size: CGSize(width: size + extra, height: size),
                                   hole: min(1, max(0, node.out.x * 1.6 - 0.6)),
                                   kind: .petal(symbol: node.petal.symbol ?? "circle", title: node.petal.title, reveal: reveal, side: side),
                                   scale: grown * (1 + 0.12 * lit), fade: arrived * standing * node.fade.x,
                                   light: formed, words: min(1, reveal), lens: formed))
        }
        for node in choice {
            let place = node.petal.place
            let grown = max(0.04, min(1.2, node.grow.x)), lit = max(0, node.highlight.x)
            let way = WheelLayout.unit(place)
            let side = way.x > 0.3 ? 1 : way.x < -0.3 ? -1 : 0
            let width = Self.label(node.petal.width) + 30, height = 34.0
            // A choice leaves the centre as a droplet on its compass line and only widens into its word as it pinches off.
            let bead = 26.0, opening = Self.smooth((node.out.x - 0.4) / 0.5)
            let others = node.leaving ? 1 : 1 - 0.08 * dim.x * (1 - min(1, lit))
            let grow = grown * (1 + 0.1 * lit) * others
            let size = CGSize(width: (bead + (width - bead) * opening) * grow, height: (bead + (height - bead) * opening) * grow)
            let pull = 1 - 3 * min(1, lit) / radius
            let restY = way.y * radius
            if !node.leaving, node.out.x > 0.85,
               let bridge = neck(node.id, place, to: side == 0 ? radius * pull - size.height / 2 : (radius - petal / 2) * pull, lit: lit) {
                list.append(bridge)
            }
            // Its near edge travels like a petal's, from inside the centre to its resting gap, and the word grows outward
            // from there: a pill sent straight to its resting centre shoots out as a detached bead.
            let inner = -bead / 2 + (radius - petal / 2 + bead / 2) * node.out.x * pull
            let at = CGPoint(x: side == 0 ? 0 : Double(side) * (inner + size.width / 2), y: restY * node.out.x * pull)
            let formed = max(0, min(1, (node.out.x - 0.72) / 0.25))
            list.append(WheelPiece(id: node.id, centre: CGPoint(x: hub.x + at.x, y: hub.y + at.y), size: size,
                                   hole: min(1, max(0, node.out.x * 1.6 - 0.6)), kind: .pill(title: node.petal.title), scale: min(1, grown),
                                   fade: Self.smooth((node.out.x - 0.55) / 0.4) * (node.leaving ? 1 : (place == live ? 1 : quiet)) * node.fade.x,
                                   light: formed, words: opening, lens: formed))
        }
        if present.x > 0.03 {
            // A field keeps the drop's clear glass, with the lens under its words.
            list.append(WheelPiece(id: "centre", centre: centrePoint, size: centreSize, hole: 1, kind: .centre, scale: centreScale,
                                   fade: reduceMotion ? min(1, present.x) : 1, lens: fieldOpen))
        }
        return list
    }

    /// The piece under `point`: a petal or pill of the ring that answers the pointer, else the centre.
    func hit(_ point: CGPoint) -> WheelHit? {
        let frames = pieces()
        let centre = frames.first { $0.id == "centre" }
        for node in ring where !node.leaving && node.out.x > 0.05 {
            guard let piece = frames.first(where: { $0.id == node.id }), Self.inside(point, piece) else { continue }
            // Petals that have not left the centre yet sit under it: a click there is the centre's.
            if let centre, Self.frame(piece).insetBy(dx: -5, dy: -5).intersects(Self.frame(centre)) { continue }
            return .place(node.petal.place)
        }
        if let centre, Self.inside(point, centre) { return .centre }
        return nil
    }

    private static func frame(_ piece: WheelPiece) -> CGRect {
        CGRect(x: piece.centre.x - piece.size.width / 2, y: piece.centre.y - piece.size.height / 2, width: piece.size.width, height: piece.size.height)
    }

    private static func inside(_ point: CGPoint, _ piece: WheelPiece) -> Bool { frame(piece).insetBy(dx: -5, dy: -5).contains(point) }

    /// Names longer than the limit are drawn cut, so a piece never grows past the canvas placement assumes.
    private static func label(_ width: Double) -> Double { min(width, WheelLayout.nameLimit) }

    private static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// A short liquid bridge from the centre to whatever is pointed at: one concave piece of glass, overlapping both ends,
    /// so it reads as the drop reaching out whatever the merge distance is. Its width follows the highlight spring, which
    /// is what hands it from one petal to the next without a pop.
    private func neck(_ id: String, _ place: ActionPlace, to edge: Double, lit: Double) -> WheelPiece? {
        guard !reduceMotion else { return nil }
        let from = WheelLayout.drop / 2 * centreScale - 6, length = edge + 6 - from
        guard lit > 0.03, length > 8 else { return nil }
        let way = WheelLayout.unit(place), mid = from + length / 2, amount = min(1.1, lit)
        return WheelPiece(id: id + "-neck", centre: CGPoint(x: WheelLayout.hub.x + way.x * mid, y: WheelLayout.hub.y + way.y * mid),
                          size: CGSize(width: length + 24, height: length + 24), hole: 0,
                          kind: .neck(angle: atan2(way.y, way.x), length: length, end: 23 * amount, waist: 11 * amount), scale: 1, fade: 1)
    }
}
