import AppKit
import SwiftUI

/// The quiet drop: a Liquid Glass droplet carrying the oops eyes as two slight, unequal dashes.
///
/// Refined over decorated: the system's glass supplies the lensing, frost and edge light; the
/// app adds only what real glass shows — a faint top sheen, a hairline edge brighter at the top —
/// and, while working, a soft colourless highlight travelling round the edge, like light catching
/// a turning drop, while the eyes read. A wide drop keeps that light in the eye slot at its
/// leading end, clear of the label, and a narrating one counts its time at the trailing end.
///
/// One animated width drives the glass, the light, the eyes and the label reveal, so the morph
/// stays in sync. The drop pops in from small and shrinks out from its centre on dismissal. Light
/// is drawn outside the glass container: attached to glass it is absorbed as glass content.
struct EyesDropView: View {
    @ObservedObject var model: CapsuleModel
    /// Every size times this: onboarding draws the drop at its camera's zoom, natively rather than magnified.
    var scale: CGFloat = 1
    #if DEBUG
    var previewAccessibility: Set<String> = []
    #endif
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    /// Lab override, since these settings are read-only to the app: `CapsuleAccessibility` lists
    /// any of reduce-motion, reduce-transparency, increase-contrast. The system glass ignores it.
    static let forced = DebugFlags.capsuleAccessibility
    private var accessibilityOverrides: Set<String> {
        #if DEBUG
        Self.forced.union(previewAccessibility)
        #else
        Self.forced
        #endif
    }
    private var reduceMotion: Bool { systemReduceMotion || accessibilityOverrides.contains("reduce-motion") }
    private var reduceTransparency: Bool { systemReduceTransparency || accessibilityOverrides.contains("reduce-transparency") }
    private var increasedContrast: Bool { contrast == .increased || accessibilityOverrides.contains("increase-contrast") }
    @State private var start = Date()
    /// The drawn width, animated by `morph`.
    @State private var shown: CGFloat = Self.drop
    /// Where the travelling light runs, animated with `shown`: 0 at the round drop's rim, 1 in the wide drop's eye slot.
    @State private var slot = 0.0
    /// The widest the drop has been since it started working: a shorter step would otherwise narrow it and the next
    /// widen it again.
    @State private var widest: CGFloat = 0
    @State private var motion = DropMotion()
    nonisolated static let drop: CGFloat = 46
    /// Glass left at the drop's centre: enough to keep the eyes legible while the lens still shows.
    static let centerGlass = 0.45
    /// Tabular digits, so a timing doesn't jitter the drop's width.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    private var drop: CGFloat { Self.drop * scale }
    private var font: NSFont { scale == 1 ? Self.font : NSFont.monospacedDigitSystemFont(ofSize: 14 * scale, weight: .medium) }
    /// Where the label starts: past the eye slot, which is the round drop's own width.
    private var lead: CGFloat { drop + Self.gap * scale }

    private var working: Bool { model.phase == .working }
    private var expanded: Bool { ![.invoked, .working, .copied].contains(model.phase) || working && model.narrates && !model.label.isEmpty }
    /// A narrating drop counts the time its work has taken while it works.
    private var timed: Bool { working && expanded && model.startedAt != nil }
    private var painted: Bool { !increasedContrast }
    /// Clear glass does not flip its content for the backdrop, and oops cannot see what is behind
    /// it. The ink follows the appearance, which most apps share: white on dark, near-black on
    /// light. A halo of the opposite tone around the glyphs alone carries it over an app whose
    /// own theme differs, with no backing shape. Increase Contrast's solid glass needs no halo.
    private var ink: Color { scheme == .dark ? .white : Color(red: 0.06, green: 0.06, blue: 0.09) }
    private var halo: Color { increasedContrast ? .clear : (scheme == .dark ? Color.black : .white).opacity(0.85) }
    /// The feathered centre trades legibility for transparency; contrast and transparency settings keep solid glass.
    private var feathered: Bool { !reduceTransparency && !increasedContrast }
    private var cancellable: Bool { [.invoked, .working].contains(model.phase) && model.canCancel }

    /// Target width, computed rather than measured so every layer animates to the same value.
    private var width: CGFloat {
        guard expanded else { return drop }
        let text = parts.map { Self.measure($0, font) }.reduce(0, +) + CGFloat(parts.count - 1) * Self.divider * scale
        let clock = timed ? Self.clockGap * scale + clockWidth : 0
        return lead + text + clock + (actionCount > 0 ? Self.gap * scale + drop : 16 * scale)
    }
    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
    /// Breathing room either side of the label: after the eye slot, and before the action's cap.
    private static let gap: CGFloat = 6
    /// The least room between a working label and the timer.
    private static let clockGap: CGFloat = 10
    /// One action at most; dismissing is the close badge's job.
    private var actionCount: Int {
        switch model.phase {
        case .fixed: model.canRevert || model.open != nil ? 1 : 0
        case .pending: 1
        case .failed: model.remedy == nil ? 0 : 1
        default: 0
        }
    }
    /// A finished drop can be closed: hovering shows the badge, and assistive tech gets an action.
    private var closable: Bool { [.fixed, .pending, .failed, .reverted].contains(model.phase) && model.presented }
    /// Entrance and exit scale around the drop, wherever the capsule's corner is.
    private var dropAnchor: UnitPoint { UnitPoint(x: drop / 2 / max(shown, drop), y: 0.5) }

    var body: some View {
        ZStack(alignment: .leading) {
            // Behind the glass, not inside it: glass content is absorbed into its wash.
            if reduceTransparency { Capsule().fill(.background).frame(width: shown, height: drop) }
            GlassEffectContainer {
                Color.clear.frame(width: shown, height: drop)
                    .glassEffect(.clear.interactive(), in: .capsule)
            }
            .mask { if feathered { FeatheredCapsule(center: Self.centerGlass) } else { Capsule() } }
            // Only the light and the eyes tick while working; the glass and its mask stay still,
            // so a frame costs two small layers rather than the whole drop.
            if painted { GlassLight(dark: scheme == .dark).frame(width: shown, height: drop) }
            if painted, working, !reduceMotion {
                ticking { date in
                    let motion = advanced(date)
                    TravellingLight(angle: motion.angle, brightness: motion.brightness(dark: scheme == .dark), size: drop, scale: scale, slot: slot)
                }
                .frame(width: shown, height: drop, alignment: .leading)
                // Clipped and cached as the rest of the glass's light is.
                .clipShape(Capsule()).drawingGroup()
            }
            label.frame(width: shown, height: drop, alignment: .leading)
                // Beside the timer the label keeps to the room it has, fading out under the growing glass rather than
                // running into the timer. Sized from `shown`, the room moves with the glass's own spring.
                .mask(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, timed ? .clear : .black], startPoint: .leading, endPoint: .trailing).frame(width: 8 * scale)
                    }
                    .frame(width: max(0, timed ? shown - clockRoom : shown))
                }
                .overlay(alignment: .trailing) { clock }
                .clipShape(Capsule())
            ticking { date in eyes(date) }.frame(width: drop, height: drop)
        }
        // No cancel button while working: the drop itself cancels, like pressing the shortcut again.
        .contentShape(Capsule())
        .onTapGesture { if cancellable { model.cancel?() } else if model.phase == .fixed { model.open?() } }
        .overlay(alignment: .topTrailing) { closeBadge }
        .scaleEffect(model.presented ? 1 : 0.35, anchor: dropAnchor)
        .opacity(model.presented ? 1 : 0)
        .padding(14 * scale)
        // Exit: collapse into the drop first, then shrink out from its centre.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : model.presented ? .spring(duration: 0.45, bounce: 0.3) : .easeIn(duration: 0.22).delay(0.2),
                   value: model.presented)
        .onChange(of: model.phase) { _, phase in if phase == .working { start = Date() }; widest = 0; morph() }
        .onChange(of: model.label) { morph() }
        .onChange(of: model.startedAt) { morph() }
        .onChange(of: model.presented) { _, presented in
            if presented { shown = drop; slot = 0; widest = 0; morph() } else { morph(collapse: true) }
        }
        // The timer gains a digit at ten minutes, and again at a hundred: the drop makes room for it then.
        .task(id: model.startedAt) {
            guard let startedAt = model.startedAt else { return }
            for minutes in [10.0, 100] {
                let wait = startedAt.addingTimeInterval(minutes * 60).timeIntervalSinceNow
                guard wait > 0 else { continue }
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                morph()
            }
        }
        .help(cancellable ? model.words.cancel + (model.words.cancelShortcut.map { " · " + ShortcutSettings.shared.label($0) } ?? "") : model.detail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.label.isEmpty ? model.words.started : model.label)
        .accessibilityValue(expanded ? model.detail : "")
        .accessibilityHidden(!model.presented)
        .accessibilityActions {
            if cancellable { Button(model.words.cancel) { model.cancel?() } }
            if model.phase == .fixed, let open = model.open { Button(Self.openLabel) { open() } }
            if closable { Button("Dismiss") { model.dismiss?() } }
        }
    }

    /// Stretching unveils the label as the glass grows; shrinking narrows back into the drop.
    private func morph(collapse: Bool = false) {
        var target = collapse ? drop : width
        if working, !collapse { target = max(target, widest); widest = target }
        model.width = target
        // A working drop already wide grows quickly to take a longer step, so the step reads as it arrives.
        let stepping = working && !collapse && shown > drop && target > shown
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : stepping ? .spring(duration: 0.25, bounce: 0.1)
            : target > shown ? .spring(duration: 0.55, bounce: 0.16) : .spring(duration: 0.4, bounce: 0.1)) {
            shown = target; slot = expanded && !collapse ? 1 : 0
        }
    }

    /// Each frame of the working phase, at the display's refresh rate; paused otherwise.
    private func ticking(@ViewBuilder _ content: @escaping (Date) -> some View) -> some View {
        TimelineView(.animation(paused: reduceMotion || !working)) { context in content(context.date) }
    }

    /// The light's and the eyes' pace at `date`, stepped once a frame by whichever draws first.
    private func advanced(_ date: Date) -> DropMotion {
        motion.advance(to: date, start: start, activities: model.activities, lastActivity: model.lastActivity, toward: towardText)
        return motion
    }

    /// The label is unveiled by the growing glass (clipped to it), not faded in on its own.
    private var label: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: lead)
            // An outcome replaces the old label outright: a cross-fade would ghost "Fixing…" into it. A working
            // drop's steps follow one another, so the old one leaves before the new one rises into place.
            ZStack(alignment: .leading) {
                words.id(model.label).transition(working ? StepChange.transition(rise: reduceMotion ? 0 : 4 * scale) : .identity)
            }
            .animation(working ? .linear(duration: 0.2) : nil, value: model.label)
            if actionCount > 0 { Color.clear.frame(width: Self.gap * scale); actions }
        }
        .foregroundStyle(ink)
        // On exit the label fades before the glass narrows over it, rather than being cut off.
        .opacity(expanded && model.presented ? 1 : 0)
        .animation(.easeOut(duration: 0.2).delay(expanded ? 0.12 : 0), value: expanded)
        .animation(.easeOut(duration: 0.12), value: model.presented)
    }

    private var words: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Capsule().fill(ink.opacity(0.4)).frame(width: 1.5 * scale, height: 11 * scale).frame(width: Self.divider * scale)
                }
                Text(part).font(Font(font)).lineLimit(1).fixedSize().contentTransition(.identity)
            }
        }
        .modifier(Halo(color: halo))
    }

    /// The time the work has taken, pinned to the trailing end.
    private var clock: some View {
        ZStack {
            if timed, let startedAt = model.startedAt {
                DropClock(startedAt: startedAt, scale: scale, ink: ink, halo: halo).padding(.trailing, 16 * scale).transition(.opacity)
            }
        }
        .opacity(model.presented ? 1 : 0)
        // In with the label as the glass unveils it, and out quickly as the outcome arrives, so it never sits beside
        // the result's label.
        .animation(timed ? .easeOut(duration: 0.2).delay(0.12) : .easeOut(duration: 0.1), value: timed)
        .animation(.easeOut(duration: 0.12), value: model.presented)
    }
    private var clockWidth: CGFloat { model.startedAt.map { DropClock.width(since: $0, scale: scale) } ?? 0 }
    /// What the timer takes from the label: its trailing padding and itself, leaving the label's fade in the gap.
    private var clockRoom: CGFloat { 20 * scale + clockWidth }

    /// A count and a timing (`6 fixes · 5.7s`) are drawn apart by a short hairline, quieter than
    /// any glyph between them: a dot read as a typo's leftover at this size.
    private var parts: [String] { model.label.components(separatedBy: " · ") }
    private static let divider: CGFloat = 15

    /// Close, as on a macOS notification: a small glass disc while the pointer is over a finished
    /// drop, top right as on a notification. A pill has no corner, so it sits on the rim where the right
    /// cap turns 45° toward the top.
    private var closeBadge: some View {
        let size = 18 * scale, rim = drop / 2 * (1 - 1 / 2.squareRoot())
        let shown = closable && model.hovering
        return Button { model.dismiss?() } label: {
            Image(systemName: "xmark").font(.system(size: 8 * scale, weight: .bold)).foregroundStyle(ink)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true) // The drop's Dismiss action covers it.
        .offset(x: size / 2 - rim, y: rim - size / 2)
        .scaleEffect(shown ? 1 : 0.5, anchor: .center)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.2), value: shown)
    }

    // MARK: Eyes

    /// Where the draft is, from the capsule's placement: the corner it hugs faces the text.
    /// Look is normalised: -1…1 across the drop's face.
    private var towardText: CGSize {
        switch model.alignment {
        case .topLeading, .topTrailing: CGSize(width: -0.6, height: -0.5)   // below the caret: text above
        default: CGSize(width: -0.8, height: 0.45)                         // above the composer: text below
        }
    }

    private func eyes(_ date: Date) -> some View {
        let pose = pose(date)
        // A done drop's eyes swing into a check, and relax back into the side-eye as it collapses.
        let check = [.fixed, .copied].contains(model.phase) && model.presented ? 1.0 : 0
        return DashEyes(look: pose.look, lid: pose.lid, check: check, ink: ink, halo: halo)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : check > 0 ? .spring(duration: 0.5, bounce: 0.32) : .spring(duration: 0.55, bounce: 0.15),
                       value: model.phase)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0), value: model.presented)
            .accessibilityHidden(true)
    }

    /// Look and lid (0 open … 1 closed) for each moment.
    private func pose(_ date: Date) -> (look: CGSize, lid: Double) {
        switch model.phase {
        case .invoked: return (towardText, 0.15)
        case .working:
            guard !reduceMotion else { return (towardText, 0.4) }
            // Once the work reports progress the eyes follow it: reading while it moves, looking round when it stalls.
            return advanced(date).pose ?? DashEyes.readingPose(date.timeIntervalSince(start), toward: towardText)
        case .fixed, .copied: return (DashEyes.restingLook, DashEyes.restingLid) // unimpressed side-eye at the fixed draft
        case .failed, .pending: return DashEyes.failedPose // looking away, clear of the label
        case .reverted: return DashEyes.revertedPose // eyes rolled up
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .fixed where model.open != nil:
            button("arrow.turn.down.left", Self.openLabel) { model.open?() }
        case .fixed where model.canRevert:
            button("arrow.uturn.backward", model.words.revert) { model.revert?() }
        case .pending, .copied:
            button(model.copied ? "checkmark" : "doc.on.doc", model.words.copy) { if !model.copied { model.copy?() } }
        case .failed:
            switch model.remedy {
            case .retry: button("arrow.clockwise", "Try again") { model.retry?() }
            case .settings: button("gearshape", "Open Settings") { model.openSettings?() }
            case nil: EmptyView()
            }
        default: EmptyView()
        }
    }
    private static let openLabel = "Put in the draft"
    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        DropActionButton(symbol: symbol, label: label, scale: scale, action: action)
    }
}
