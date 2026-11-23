import AppKit
import SwiftUI

/// What an agent run's parked drop needs beyond the panel's model: the run's name, for its close badge; whether it
/// stays open without the pointer on it (a result just in); and a count whose every rise pulses its rim light once.
struct ParkedPill: Equatable {
    var name: String
    var open = false
    var pulse = 0
}

/// An agent run's content in the shared panel: the drop at the caret, in clear glass over its draft, or parked at the
/// screen's edge, cross-fading while the panel flies between the two.
struct AgentDropView: View {
    @ObservedObject var model: CapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: model.alignment) {
            if model.parked == nil {
                EyesDropView(model: model).transition(.opacity)
            } else {
                ParkedDropView(model: model).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.3), value: model.parked == nil)
    }
}

/// An agent run's drop while the person works in another app or field: centred at the top or the bottom of the screen
/// they are on, in regular glass as Dictate's drop is, so the system keeps it legible over any app. At work it folds
/// into a pill (0.7 of the drop) of the eyes, the ring in the eye slot and the timer; ready, the eyes' check and a dot.
/// The pointer on it, or a result just in, opens it in place to the full drop: the step and the timer, or the result
/// and its cap, with the close badge, which cancels the run or discards its result. A failure or an answer that
/// wasn't written stays open, with its action, until it goes.
struct ParkedDropView: View {
    @ObservedObject var model: CapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var motion = DropMotion()
    @State private var start = Date()

    static let pill: CGFloat = 0.7
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    private static let drop = EyesDropView.drop
    private var working: Bool { model.phase == .working }
    /// A result waiting to be taken back to its draft.
    private var ready: Bool { model.phase == .fixed && model.open != nil }
    /// Only work under way and a waiting result fold into the pill.
    private var open: Bool { !(working || ready) || model.hovering || model.parked?.open == true }
    private var scale: CGFloat { open ? 1 : Self.pill }
    private var timed: Bool { working && model.startedAt != nil }
    private var name: String { model.parked?.name ?? "" }

    /// The drop's target width, which the spring carries the face to with its scale.
    private var width: CGFloat {
        guard open else { return Self.drop * Self.pill + (timed ? Self.clockWidth(model.startedAt, 0) + 13 : ready ? 17 : 0) }
        return min(Self.drop + PillFace.gap + DropLabel.width(parts, font: Self.font, divider: PillFace.divider) + trailing, model.room)
    }
    /// After the label: the timer, the action's cap, or an end margin.
    private var trailing: CGFloat {
        timed ? 10 + Self.clockWidth(model.startedAt, 1) + 16 : action != nil ? PillFace.gap + Self.drop : 16
    }
    private var parts: [String] {
        DropLabel.fitted(model.label.components(separatedBy: " · "), room: model.room - Self.drop - PillFace.gap - trailing, font: Self.font,
                         divider: PillFace.divider)
    }
    static func clockWidth(_ startedAt: Date?, _ open: CGFloat) -> CGFloat {
        startedAt.map { DropLabel.measure(DropClock.text(since: $0, at: Date()), PillFace.clockFont(open)) } ?? 0
    }

    private var action: DropAction? {
        switch model.phase {
        case .fixed where model.open != nil:
            DropAction(symbol: "arrow.turn.down.left", label: "Put in the draft") { model.open?() }
        case .pending, .copied:
            DropAction(symbol: model.copied ? "checkmark" : "doc.on.doc", label: model.words.copy) { if !model.copied { model.copy?() } }
        case .failed:
            switch model.remedy {
            case .retry: DropAction(symbol: "arrow.clockwise", label: "Try again") { model.retry?() }
            case .settings: DropAction(symbol: "gearshape", label: "Open Settings") { model.openSettings?() }
            case nil: nil
            }
        default: nil
        }
    }

    var body: some View {
        PillFace(s: scale, w: width, model: model, parts: parts, action: action, motion: motion, start: start,
                 reduceMotion: reduceMotion, dark: scheme == .dark)
            // The pointer's spring wins when it moves the scale and the width together; a new step only widens.
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : open ? .spring(duration: 0.4, bounce: 0.18) : .spring(duration: 0.4, bounce: 0.1),
                       value: open)
            .animation(.spring(duration: 0.3, bounce: 0.1), value: width)
            .modifier(Glow(pulse: model.parked?.pulse ?? 0, reduceMotion: reduceMotion))
            .overlay(alignment: .topTrailing) { badge }
            .contentShape(Capsule())
            // Running, a click does nothing: cancelling is the badge's or the menu's.
            .onTapGesture { if ready { model.open?() } }
            .scaleEffect(model.presented ? 1 : 0.35)
            .opacity(model.presented ? 1 : 0)
            .padding(14)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : model.presented ? .spring(duration: 0.45, bounce: 0.3) : .easeIn(duration: 0.22),
                       value: model.presented)
            .onAppear { model.width = width }
            .onChange(of: width) { model.width = width }
            .onChange(of: model.phase) { if working { start = Date() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.label)
            .accessibilityValue(model.detail)
            .accessibilityHidden(!model.presented)
            .accessibilityActions {
                if working, model.canCancel { Button("Cancel " + name) { model.cancel?() } }
                if let action { Button(action.label) { action.perform() } }
                if !working { Button("Dismiss") { model.dismiss?() } }
            }
    }

    /// Close, as on the caret's drop: on the rim while the pointer is on the open drop. It cancels a run at work.
    private var badge: some View {
        let size: CGFloat = 18, rim = Self.drop / 2 * (1 - 1 / 2.squareRoot())
        let shown = open && model.hovering && model.presented && (!working || model.canCancel)
        return Button { if working { model.cancel?() } else { model.dismiss?() } } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.primary)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(working ? "Cancel " + name : ready ? "Discard" : "Dismiss")
        .accessibilityHidden(true) // The drop's own actions cover it.
        .offset(x: size / 2 - rim, y: rim - size / 2)
        .scaleEffect(shown ? 1 : 0.5)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.2), value: shown)
    }
}

/// The parked drop at scale `s` (0.7 folded … 1 open) and width `w`, both animated together, so every size inside it,
/// the type's included, follows one spring: what is shown only open fades in with the scale.
private struct PillFace: View, Animatable {
    var s: CGFloat, w: CGFloat
    let model: CapsuleModel, parts: [String], action: DropAction?, motion: DropMotion, start: Date
    let reduceMotion: Bool, dark: Bool
    static let gap: CGFloat = 6, divider: CGFloat = 15
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(s, w) }
        set { s = newValue.first; w = newValue.second }
    }

    /// The timer reads at 11 pt medium folded, where 13 × 0.7 would not, and at the drop's 13 pt regular open.
    static func clockFont(_ open: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: 11 + 2 * open, weight: NSFont.Weight(0.23 * (1 - open)))
    }

    private var working: Bool { model.phase == .working }
    /// 0 folded … 1 open.
    private var openness: CGFloat { min(max((s - ParkedDropView.pill) / (1 - ParkedDropView.pill), 0), 1) }

    var body: some View {
        let h = EyesDropView.drop * s, e = openness
        let lead = h + Self.gap * s
        let reserve = working ? ParkedDropView.clockWidth(model.startedAt, e) + 20 : action != nil ? h - 2 : 8
        ZStack(alignment: .leading) {
            if working, !reduceMotion { ticking { ring(advanced($0), h: h) } }
            words
                .frame(width: max(0, w - lead - reserve), height: h, alignment: .leading)
                .mask(alignment: .leading) {
                    HStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 8) }
                }
                .padding(.leading, lead)
                .opacity(Double(e * e))
            if working, let startedAt = model.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(DropClock.text(since: startedAt, at: context.date)).font(Font(Self.clockFont(e))).fixedSize()
                }
                .foregroundStyle(.secondary)
                .padding(.trailing, 12 + 4 * e)
                .frame(width: w, alignment: .trailing)
            }
            if model.phase == .fixed, model.open != nil {
                Circle().fill(.primary).frame(width: 5, height: 5).padding(.trailing, 12)
                    .frame(width: w, alignment: .trailing).opacity(Double(1 - e))
            }
            if let action {
                DropActionButton(symbol: action.symbol, label: action.label, scale: s, action: action.perform)
                    .frame(width: w, alignment: .trailing).opacity(Double(e)).allowsHitTesting(e > 0.5)
            }
            ticking { eyes($0, h: h) }
        }
        .foregroundStyle(.primary)
        .frame(width: w, height: h)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var words: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Capsule().fill(.primary.opacity(0.4)).frame(width: 1.5 * s, height: 11 * s).frame(width: Self.divider * s) }
                Text(part).font(.system(size: 14 * s, weight: .medium).monospacedDigit()).lineLimit(1).fixedSize()
            }
        }
    }

    /// Each frame while at work, as the caret's drop ticks; still otherwise.
    private func ticking(@ViewBuilder _ content: @escaping (Date) -> some View) -> some View {
        TimelineView(.animation(paused: reduceMotion || !working)) { context in content(context.date) }
    }

    private static let toward = CGSize(width: -0.8, height: 0.45)
    private func advanced(_ date: Date) -> DropMotion {
        motion.advance(to: date, start: start, run: model.run, activities: model.activities, lastActivity: model.lastActivity, toward: Self.toward)
        return motion
    }

    /// `GlassLight`'s travelling arc, kept in the eye slot, in the glass's own ink.
    private func ring(_ motion: DropMotion, h: CGFloat) -> some View {
        let peak = motion.brightness(dark: dark)
        return Circle().trim(from: 0, to: 0.16)
            .stroke(AngularGradient(colors: [.primary.opacity(0), .primary.opacity(peak), .primary.opacity(0)], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(58)),
                    style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round))
            .frame(width: 34 * s, height: 34 * s)
            .rotationEffect(.radians(motion.angle - .pi / 2))
            .blur(radius: 0.7)
            .frame(width: h, height: h)
    }

    private func eyes(_ date: Date, h: CGFloat) -> some View {
        let pose: (look: CGSize, lid: Double) = switch model.phase {
        case .working: reduceMotion ? (Self.toward, 0.4) : advanced(date).pose ?? DashEyes.readingPose(date.timeIntervalSince(start), toward: Self.toward)
        case .failed, .pending: DashEyes.failedPose
        case .reverted: DashEyes.revertedPose
        default: (DashEyes.restingLook, DashEyes.restingLid)
        }
        let check = [.fixed, .copied].contains(model.phase) ? 1.0 : 0
        return DashEyes(look: pose.look, lid: pose.lid, check: check, ink: .primary, halo: .clear)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.32), value: model.phase)
            .frame(width: h, height: h)
            .accessibilityHidden(true)
    }
}

/// A result just in: a white rim light swells and fades once, about 0.9 s, each time `pulse` rises. With Reduce
/// Motion the glass brightens a touch instead.
private struct Glow: ViewModifier {
    let pulse: Int, reduceMotion: Bool

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: pulse) { view, glow in
            view
                .overlay {
                    if !reduceMotion, glow > 0.001 {
                        ZStack {
                            Capsule().strokeBorder(.white.opacity(glow), lineWidth: 1.4)
                            Capsule().strokeBorder(.white.opacity(glow), lineWidth: 5).blur(radius: 4)
                        }
                        .clipShape(Capsule())
                        .allowsHitTesting(false)
                    }
                }
                .brightness(reduceMotion ? glow * 0.15 : 0)
        } keyframes: { _ in
            CubicKeyframe(0.6, duration: 0.45)
            CubicKeyframe(0, duration: 0.45)
        }
    }
}
