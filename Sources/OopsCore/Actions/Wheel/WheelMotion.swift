import CoreGraphics
import Foundation

/// What one petal or pill shows.
public struct WheelPetal: Equatable, Sendable {
    public var place: ActionPlace, title: String, symbol: String?
    /// The title's measured width in the label font, which sets how far the petal widens to show it.
    public var width: Double

    public init(place: ActionPlace, title: String, symbol: String?, width: Double) {
        self.place = place
        self.title = title
        self.symbol = symbol
        self.width = width
    }
}

/// One petal or pill on its way out, resting, or on its way back.
public struct WheelNode: Equatable, Sendable, Identifiable {
    public let id: String
    public let petal: WheelPetal
    public var out = WheelSpring(), grow = WheelSpring(), highlight = WheelSpring(), name = WheelSpring(), fade = WheelSpring()
    public var leaving = false, chosen = false
    /// Closing reabsorbs faster than opening, with no bounce.
    public var quick = false
}

/// The wheel's motion: petals bud out of the centre one after another, the centre recoiling from each, and flow back
/// the way they came. Every spring is stepped by hand, so a frame is a pure function of the steps before it.
public struct WheelMotion: Equatable, Sendable {
    /// Things that happen a moment after the call that scheduled them. A cue made under one epoch dies when a later
    /// call bumps it (a new opening, a choice), unless it is `always`: a petal already on its way back finishes the trip.
    enum Cue: Equatable, Sendable { case launch(String), leave(String), swallow, centreLeaves }
    struct Pending: Equatable, Sendable {
        var at: TimeInterval, epoch: Int, always: Bool, cue: Cue
    }

    /// Reduce Motion: petals stay in place and cross-fade, with no travel, necks, recoil or dip.
    public var reduceMotion: Bool
    public private(set) var clock: TimeInterval = 0
    public private(set) var root: [WheelNode] = [], choice: [WheelNode] = []
    public private(set) var present = WheelSpring(), width = WheelSpring(WheelLayout.drop), recoilX = WheelSpring(), recoilY = WheelSpring()
    public private(set) var dip = WheelSpring(1), iconMix = WheelSpring(), check = WheelSpring(), dim = WheelSpring()
    public private(set) var live: ActionPlace?
    public private(set) var named = false
    /// The words under the centre that say it takes typing; and whether the centre is a field.
    public private(set) var hint = WheelSpring(), typing = false
    /// What the centre shows once a petal has flowed into it.
    public private(set) var symbol: String?
    var cues: [Pending] = []
    private var epoch = 0, bloomed = false

    public init(reduceMotion: Bool = false) { self.reduceMotion = reduceMotion }

    /// The ring that answers the pointer: the second ring once it has anything staying, else the first.
    var ring: [WheelNode] { choice.contains { !$0.leaving } ? choice : root }

    // MARK: Opening and closing

    public mutating func open() {
        epoch += 1
        live = nil
        named = false
        typing = false
        hint.target = 0
        bloomed = false
        symbol = nil
        iconMix.target = 0
        check.target = 0
        dim.target = 0
        width.target = WheelLayout.drop
        present.target = 1
        for index in root.indices {
            root[index].leaving = true
            if reduceMotion {
                root[index].fade.target = 0
            } else {
                root[index].out.target = 0
                root[index].grow.target = 0
            }
        }
        retract(\.choice, chosen: nil)
        relax()
    }

    /// The first ring, one petal after another: cardinals every `stagger`, then diagonals as a second wave that starts
    /// while the cardinals are still travelling, after their necks have thinned.
    public mutating func bloom(_ petals: [WheelPetal]) {
        bloomed = true
        root = launch(petals, prefix: "r")
    }

    public mutating func bloomChoices(_ pills: [WheelPetal]) {
        choice = launch(pills, prefix: "c")
    }

    /// An early arrow: petals not out yet stay in, and the ones already budding go back quickly.
    public mutating func skipBloom() {
        cues.removeAll { if case .launch = $0.cue { true } else { false } }
        for ring in [\WheelMotion.root, \WheelMotion.choice] {
            var nodes = self[keyPath: ring]
            nodes.removeAll { $0.out.target == 0 && !$0.leaving }
            for index in nodes.indices where !nodes[index].leaving {
                nodes[index].leaving = true
                nodes[index].quick = true
                if reduceMotion { nodes[index].fade.target = 0 } else { nodes[index].out.target = 0 }
            }
            self[keyPath: ring] = nodes
        }
    }

    /// What is pointed at grows and the rest step back; the centre leans toward it.
    public mutating func setLive(_ place: ActionPlace?) {
        live = place
        let pointer = choice.contains { !$0.leaving } ? \WheelMotion.choice : \WheelMotion.root
        for index in self[keyPath: pointer].indices where !self[keyPath: pointer][index].leaving {
            self[keyPath: pointer][index].highlight.target = self[keyPath: pointer][index].petal.place == place ? 1 : 0
        }
        dim.target = place == nil ? 0 : 1
        if !reduceMotion {
            let way = place.map(WheelLayout.unit) ?? .zero
            recoilX.target = way.x * 3
            recoilY.target = way.y * 3
        }
    }

    /// Every staying petal says its name.
    public mutating func showNames() {
        named = true
        for index in root.indices where !root[index].leaving { root[index].name.target = 1 }
    }

    /// The words under the centre come out with the names.
    public mutating func showHint() { hint.target = 1 }

    /// The centre widens into a field and both rings go back into it.
    public mutating func beginTyping() {
        epoch += 1
        typing = true
        live = nil
        dim.target = 0
        named = false
        hint.target = 0
        width.target = WheelLayout.field
        relax()
        retract(\.root, chosen: nil)
        retract(\.choice, chosen: nil)
    }

    /// The field closes back into the drop.
    public mutating func endTyping() {
        typing = false
        width.target = WheelLayout.drop
    }

    /// How far the centre has widened into its field, 0 to 1.
    public var fieldOpen: Double { min(1, max(0, (width.x - WheelLayout.drop) / (WheelLayout.field - WheelLayout.drop))) }

    /// The chosen petal flows into the centre, which shows its symbol; the rest of its ring goes back.
    public mutating func select(_ place: ActionPlace?, symbol: String) {
        epoch += 1
        hint.target = 0
        self.symbol = symbol
        iconMix.target = 1
        live = nil
        dim.target = 0
        named = false
        relax()
        retract(choice.contains { !$0.leaving } ? \.choice : \.root, chosen: place)
    }

    /// Everything goes back into the centre, which leaves last.
    public mutating func close() {
        epoch += 1
        live = nil
        named = false
        typing = false
        hint.target = 0
        dim.target = 0
        width.target = WheelLayout.drop
        relax()
        retract(\.root, chosen: nil, quick: true)
        retract(\.choice, chosen: nil, quick: true)
        if reduceMotion {
            present.target = 0
        } else {
            cues.append(Pending(at: clock + (root.count > 4 ? 0.11 : 0.09), epoch: epoch, always: false, cue: .centreLeaves))
        }
    }

    // MARK: Stepping

    public mutating func step(_ dt: Double) {
        clock += dt
        let due = cues.filter { $0.at <= clock }
        cues.removeAll { $0.at <= clock }
        for pending in due where pending.always || pending.epoch == epoch { run(pending.cue) }
        for index in root.indices { Self.step(&root[index], dt) }
        for index in choice.indices { Self.step(&choice[index], dt) }
        let reduced = reduceMotion
        root.removeAll { Self.gone($0, reduced) }
        choice.removeAll { Self.gone($0, reduced) }
        let opening = present.target != 0
        present.step(dt, reduceMotion ? 0.2 : (opening ? 0.24 : 0.13), reduceMotion ? 1 : (opening ? 0.6 : 1))
        width.step(dt, 0.42, 0.78)
        recoilX.step(dt, 0.3, 0.45)
        recoilY.step(dt, 0.3, 0.45)
        dip.step(dt, 0.32, 0.42)
        iconMix.step(dt, 0.2, 1)
        hint.step(dt, 0.3, 0.85)
        check.step(dt, 0.4, 0.6)
        dim.step(dt, 0.2, 1)
    }

    /// Every staying petal at rest: arrived, still and fully grown.
    public var settled: Bool {
        bloomed && root.filter { !$0.leaving }.allSatisfy { abs($0.out.x - 1) < 0.02 && abs($0.out.v) < 0.8 && abs($0.grow.x - 1) < 0.04 }
    }

    /// Nothing moves and nothing is scheduled: another step would draw the same frame.
    public var resting: Bool {
        cues.isEmpty && [present, width, recoilX, recoilY, dip, iconMix, check, dim, hint].allSatisfy(\.resting)
            && (root + choice).allSatisfy { [$0.out, $0.grow, $0.highlight, $0.name, $0.fade].allSatisfy(\.resting) }
    }

    /// Nothing left to draw: the window can go.
    public var gone: Bool { present.target == 0 && present.x < 0.03 && root.isEmpty && choice.isEmpty }

    // MARK: Parts

    private static func step(_ node: inout WheelNode, _ dt: Double) {
        node.out.step(dt, node.quick ? 0.15 : WheelLayout.response, node.quick ? 1 : WheelLayout.damping)
        node.grow.step(dt, node.quick ? 0.13 : WheelLayout.response * 0.85, node.quick ? 1 : 0.9)
        node.highlight.step(dt, 0.22, 0.68)
        node.name.step(dt, 0.3, 0.85)
        node.fade.step(dt, 0.2, 1)
    }

    private static func gone(_ node: WheelNode, _ reduced: Bool) -> Bool {
        guard node.leaving else { return false }
        return reduced ? node.fade.x < 0.02 : node.out.x < 0.04 || node.grow.x < 0.06
    }

    private mutating func relax() {
        recoilX.target = 0
        recoilY.target = 0
    }

    private mutating func run(_ cue: Cue) {
        switch cue {
        case let .launch(id):
            guard let place = (root + choice).first(where: { $0.id == id })?.petal.place else { return }
            update(id) { node in
                node.out.target = 1
                node.grow.target = 1
            }
            let away = WheelLayout.unit(place)
            recoilX.v -= away.x * 70
            recoilY.v -= away.y * 70
        case let .leave(id):
            update(id) { node in
                node.out.target = 0
                node.grow.target = 0.45
            }
        case .swallow: dip.v += 1.6
        case .centreLeaves: present.target = 0
        }
    }

    private mutating func update(_ id: String, _ change: (inout WheelNode) -> Void) {
        if let index = root.firstIndex(where: { $0.id == id }) {
            var node = root[index]
            change(&node)
            root[index] = node
        } else if let index = choice.firstIndex(where: { $0.id == id }) {
            var node = choice[index]
            change(&node)
            choice[index] = node
        }
    }

    private mutating func launch(_ petals: [WheelPetal], prefix: String) -> [WheelNode] {
        let sorted = petals.sorted { (WheelLayout.slot($0.place) % 2, WheelLayout.slot($0.place)) < (WheelLayout.slot($1.place) % 2, WheelLayout.slot($1.place)) }
        let cardinals = sorted.filter { !$0.place.isDiagonal }.count
        return sorted.enumerated().map { index, petal in
            var node = WheelNode(id: "\(prefix)\(WheelLayout.slot(petal.place))-\(epoch)", petal: petal)
            if reduceMotion {
                node.out = WheelSpring(1)
                node.grow = WheelSpring(1)
                node.fade.target = 1
            } else {
                // Only Reduce Motion fades; the travelling petal is drawn from the first frame.
                node.fade = WheelSpring(1)
                // A pill starts nearer its full size than a petal: it is a word, not a bead.
                node.grow = WheelSpring(petal.symbol == nil ? 0.6 : 0.3)
                let delay = petal.place.isDiagonal ? WheelLayout.wave + Double(index - cardinals) * WheelLayout.stagger : Double(index) * WheelLayout.stagger
                cues.append(Pending(at: clock + delay, epoch: epoch, always: false, cue: .launch(node.id)))
            }
            return node
        }
    }

    /// The reverse of how they came; the chosen one flows straight back into the centre.
    private mutating func retract(_ ring: WritableKeyPath<WheelMotion, [WheelNode]>, chosen: ActionPlace?, quick: Bool = false) {
        var nodes = self[keyPath: ring]
        let pick = chosen.flatMap { place in nodes.firstIndex { $0.petal.place == place && !$0.leaving } }
        let rest = nodes.indices.filter { $0 != pick && !nodes[$0].leaving }
            .sorted { (WheelLayout.slot(nodes[$0].petal.place) % 2, WheelLayout.slot(nodes[$0].petal.place))
                > (WheelLayout.slot(nodes[$1].petal.place) % 2, WheelLayout.slot(nodes[$1].petal.place))
            }
        for (order, index) in rest.enumerated() {
            nodes[index].leaving = true
            nodes[index].quick = quick
            nodes[index].highlight.target = 0
            nodes[index].name.target = 0
            if reduceMotion {
                nodes[index].fade.target = 0
            } else {
                cues.append(Pending(at: clock + Double(order) * (quick ? 0.006 : WheelLayout.stagger * 0.6), epoch: epoch, always: true, cue: .leave(nodes[index].id)))
            }
        }
        if let pick {
            nodes[pick].leaving = true
            nodes[pick].chosen = true
            nodes[pick].highlight.target = 0
            nodes[pick].name.target = 0
            if reduceMotion {
                nodes[pick].fade.target = 0
            } else {
                nodes[pick].out.target = 0
                nodes[pick].grow.target = 0.55
                // The centre swallows it.
                cues.append(Pending(at: clock + 0.09, epoch: epoch, always: true, cue: .swallow))
            }
        }
        self[keyPath: ring] = nodes
    }
}
