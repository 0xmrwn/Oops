import AppKit
import OopsCore
import SwiftUI

/// The wheel: clear glass pieces that merge as they travel, with each piece's icon and name drawn over the glass in
/// one ink, a soft halo and a blurred lens beneath it, as Fix's drop draws its eyes. The pointer and the keys reach
/// it through its tap, never through this view.
struct WheelView: View {
    let frame: WheelFrame

    static let darkInk = Color(red: 0.06, green: 0.06, blue: 0.09)
    private static let label = Font(NSFont.systemFont(ofSize: WheelLayout.labelSize, weight: .medium))
    private static let hintFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    var body: some View {
        let motion = frame.motion, ink = frame.ink
        let pieces = motion.pieces()
        // The words under the drop sit on the page, not on glass: they get a lens of their own.
        let lensed = pieces.filter { $0.lens > 0.01 } + hintLens(motion)
        // Glass ignores opacity: under Reduce Motion its mask does the cross-fade.
        let fades = motion.reduceMotion ? Self.fades(motion) : nil
        let edge = ink.dark ? WheelLayout.edge : 0
        ZStack {
            if edge > 0.01 { EdgeShade(pieces: pieces, amount: edge, travel: motion.travel, hairline: false, fades: fades) }
            // Behind the glass, not inside it: glass content is absorbed into its wash.
            if frame.reduceTransparency {
                ForEach(pieces) { piece in piece.path.fill(.background).opacity(fades?[piece.id] ?? 1) }
            }
            GlassEffectContainer(spacing: motion.spacing) {
                ZStack {
                    ForEach(pieces) { piece in
                        let shape = Self.outline(piece)
                        Color.clear
                            .frame(width: piece.size.width, height: piece.size.height)
                            .glassEffect(piece.kind == .centre ? .clear.interactive() : .clear, in: shape)
                            .position(piece.centre)
                    }
                }
                .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.height)
            }
            .mask { FeatherMask(pieces: pieces, holes: !ink.plain, fades: fades) }
            if !ink.plain {
                // Regular glass is the lens: in its own container so it never merges with the clear glass, and
                // masked to sit only under the content, with no edge of its own.
                GlassEffectContainer(spacing: 0) {
                    ZStack {
                        ForEach(lensed) { piece in
                            Color.clear.frame(width: piece.size.width, height: piece.size.height)
                                .glassEffect(.regular, in: .capsule).position(piece.centre)
                        }
                    }
                    .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.height)
                }
                .mask { LensMask(pieces: lensed, strength: WheelLayout.lens, fades: fades) }
            }
            if edge > 0.01 { EdgeShade(pieces: pieces, amount: edge, travel: motion.travel, hairline: true, fades: fades) }
            if !frame.increaseContrast {
                // Each petal gets the drop's own edge light once it has pinched off; before that the rims would cross
                // the neck.
                ForEach(pieces.filter { $0.light > 0.01 }) { piece in
                    GlassLight(dark: !ink.dark)
                        .frame(width: piece.size.width, height: piece.size.height)
                        .opacity(piece.light * (fades?[piece.id] ?? 1))
                        .position(piece.centre)
                }
            }
            ForEach(pieces.filter(\.carriesWords)) { piece in
                face(piece).frame(width: piece.size.width, height: piece.size.height).clipShape(Capsule())
                    .modifier(WheelInkStyle(ink: ink))
                    .opacity(piece.fade).position(piece.centre)
            }
            centreFace(motion, ink)
            choices(motion, pieces)
        }
        .frame(width: WheelLayout.canvas.width, height: WheelLayout.canvas.height)
        // The glass and the system's styles take the tone the ink was chosen for.
        .environment(\.colorScheme, ink.dark ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private static func outline(_ piece: WheelPiece) -> AnyShape {
        if case let .neck(angle, length, end, waist) = piece.kind { return AnyShape(NeckShape(angle: angle, length: length, end: end, waist: waist)) }
        return AnyShape(Capsule())
    }

    /// Each piece's own fade, which Reduce Motion cross-fades; the centre comes and goes with its presence.
    private static func fades(_ motion: WheelMotion) -> [String: Double] {
        var fades = Dictionary((motion.root + motion.choice).map { ($0.id, $0.fade.x) }) { a, _ in a }
        fades["centre"] = min(1, motion.present.x)
        return fades
    }

    /// A petal's icon and name, or a choice's word.
    @ViewBuilder private func face(_ piece: WheelPiece) -> some View {
        switch piece.kind {
        case let .petal(symbol, title, reveal, side):
            let height = piece.size.height
            // The name takes exactly the room the glass has grown by, so the icon never leaves its slot.
            let room = max(0, piece.size.width - height)
            let label = Text(title).font(Self.label).tracking(WheelLayout.tracking).lineLimit(1).truncationMode(.tail)
                .frame(width: width(title), alignment: side < 0 ? .trailing : .leading)
                .opacity(min(1, reveal * 1.4))
                .padding(side < 0 ? .leading : .trailing, 15).padding(side < 0 ? .trailing : .leading, 2)
                .frame(width: room, alignment: side < 0 ? .trailing : .leading).clipped()
            HStack(spacing: 0) {
                if side < 0 { label }
                Image(systemName: symbol).font(.system(size: 16 * piece.scale, weight: .semibold))
                    .frame(width: height, height: height)
                if side >= 0 { label }
            }
            .frame(width: piece.size.width, height: height)
        case let .pill(title):
            Text(title).font(.system(size: WheelLayout.labelSize * piece.scale, weight: .medium))
                .tracking(WheelLayout.tracking).lineLimit(1).truncationMode(.tail)
                .frame(width: width(title) * piece.scale)
        default: EmptyView()
        }
    }

    /// The measured width, a point of slack so rounding never cuts a name that fits, and at most the limit.
    private func width(_ title: String) -> Double { min(WheelLayout.nameLimit, frame.widths[title] ?? WheelLayout.nameLimit) + 1 }

    /// Fix's drop's own light and eyes, and once a petal has flowed in, its icon: all drawn over the glass.
    @ViewBuilder private func centreFace(_ motion: WheelMotion, _ ink: WheelInk) -> some View {
        if motion.present.x > 0.03 {
            let size = motion.centreSize, point = motion.centrePoint, scale = motion.centreScale
            let shown = motion.reduceMotion ? min(1, motion.present.x) : min(1, motion.present.x * 1.5)
            let face = CGPoint(x: point.x - size.width / 2 + size.height / 2, y: point.y)
            let tone = ink.dark ? Self.darkInk : Color.white
            if !frame.increaseContrast {
                GlassLight(dark: !ink.dark)
                    .frame(width: size.width, height: size.height).opacity(motion.reduceMotion ? shown : 1).position(point)
            }
            let look = Self.look(motion.live), eyes = max(0, 1 - motion.iconMix.x) * shown
            // The cue's glance travels to the words; under Reduce Motion it is a cross-fade between the two still poses.
            let glance = motion.reduceMotion ? 0 : max(0, motion.glance.x)
            let dissolve = motion.reduceMotion ? min(1, max(0, motion.glance.x)) : 0
            ForEach(dissolve > 0.01 ? [0, 1] : [0], id: \.self) { pose in
                let down = pose == 1 ? 1 : glance
                DashEyes(look: CGSize(width: look.width + (WheelCue.look.width - look.width) * down,
                                      height: look.height + (WheelCue.look.height - look.height) * down),
                         lid: 0.15 + (WheelCue.lid - 0.15) * down, check: motion.check.x, ink: tone,
                         halo: ink.plain ? .clear : (ink.dark ? Color.white : .black).opacity(0.85))
                    .frame(width: WheelLayout.drop, height: WheelLayout.drop)
                    .scaleEffect(scale)
                    .opacity(eyes * (pose == 1 ? dissolve : 1 - dissolve))
                    .position(face)
                    .animation(.spring(duration: 0.3, bounce: 0.1), value: motion.live)
            }
            if let symbol = motion.symbol {
                Image(systemName: symbol).font(.system(size: 17 * scale, weight: .semibold))
                    .modifier(WheelInkStyle(ink: ink))
                    .opacity(motion.iconMix.x * shown)
                    .scaleEffect(0.7 + 0.3 * motion.iconMix.x)
                    .position(face)
            }
            if motion.hint.x > 0.01 {
                // Words saying what to type, and nothing that blinks or looks like a caret: that would claim a focus
                // the person never gave. The cue's own words are at full ink.
                Text(frame.hintText).font(Font(Self.hintFont)).lineLimit(1).fixedSize()
                    .modifier(WheelInkStyle(ink: ink, strength: motion.cueWords ? 1 : 0.8))
                    .opacity(min(1, motion.hint.x))
                    .position(Self.hintPoint)
            }
        }
    }

    private static let hintPoint = CGPoint(x: WheelLayout.hub.x, y: WheelLayout.hub.y + WheelLayout.drop / 2 + 12)

    /// The petals' lens, under the words below the drop while they show.
    private func hintLens(_ motion: WheelMotion) -> [WheelPiece] {
        guard motion.hint.x > 0.01 else { return [] }
        let width = (frame.hintText as NSString).size(withAttributes: [.font: Self.hintFont]).width
        return [WheelPiece(id: "hint", centre: Self.hintPoint, size: CGSize(width: width + 24, height: 26), hole: 0,
                           kind: .pill(title: frame.hintText), scale: 1, fade: 1, lens: min(1, motion.hint.x))]
    }

    /// Where the eyes look: at what is pointed at, otherwise toward the text above.
    private static func look(_ live: ActionPlace?) -> CGSize {
        guard let live else { return CGSize(width: -0.6, height: -0.5) }
        let way = WheelLayout.unit(live)
        return CGSize(width: way.x * 0.85, height: way.y * 0.8)
    }

    /// One button per petal of the ring that answers, for VoiceOver: every action without arrows or a pointer.
    private func choices(_ motion: WheelMotion, _ pieces: [WheelPiece]) -> some View {
        let ring = motion.choice.contains { !$0.leaving } ? motion.choice : motion.root
        let staying = ring.filter { !$0.leaving }
        return ForEach(staying) { node in
            if let piece = pieces.first(where: { $0.id == node.id }) {
                Button { frame.choose(node.petal.place) } label: { Color.clear }
                    .buttonStyle(.plain)
                    .frame(width: piece.size.width, height: piece.size.height)
                    .position(piece.centre)
                    .accessibilityLabel("\(WheelAnnouncement.word(node.petal.place)), \(node.petal.title)")
            }
        }
    }
}

private extension WheelPiece {
    var carriesWords: Bool {
        switch kind {
        case .petal, .pill: true
        case .centre, .neck: false
        }
    }
}
