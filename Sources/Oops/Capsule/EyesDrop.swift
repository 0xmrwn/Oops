import AppKit
import SwiftUI

/// The quiet drop: a Liquid Glass droplet carrying the oops eyes as two slight, unequal dashes.
///
/// Refined over decorated: the system's glass supplies the lensing, frost and edge light; the
/// app adds only what real glass shows — a faint top sheen, a hairline edge brighter at the top —
/// and, while working, a soft colourless highlight travelling round the edge, like light catching
/// a turning drop, while the eyes read.
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
    static let drop: CGFloat = 46
    /// Glass left at the drop's centre: enough to keep the eyes legible while the lens still shows.
    static let centerGlass = 0.45
    /// Tabular digits, so a timing doesn't jitter the drop's width.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private var drop: CGFloat { Self.drop * scale }
    private var font: NSFont { scale == 1 ? Self.font : NSFont.monospacedDigitSystemFont(ofSize: 13 * scale, weight: .semibold) }

    private var working: Bool { model.phase == .working }
    private var expanded: Bool { ![.invoked, .working, .copied].contains(model.phase) }
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
        let text = parts.map { ($0 as NSString).size(withAttributes: [.font: font]).width.rounded(.up) }.reduce(0, +)
            + CGFloat(parts.count - 1) * Self.divider * scale
        return drop - 6 * scale + text + (actionCount > 0 ? Self.gap * scale + drop : 16 * scale)
    }
    /// Breathing room between the label and the action's cap.
    private static let gap: CGFloat = 6
    /// One action at most; dismissing is the close badge's job.
    private var actionCount: Int {
        switch model.phase {
        case .fixed: model.canRevert ? 1 : 0
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
            if painted { ticking { t in GlassLight(t: t, travelling: working && !reduceMotion, dark: scheme == .dark) }.frame(width: shown, height: drop) }
            label.frame(width: shown, height: drop, alignment: .leading).clipShape(Capsule())
            ticking { t in eyes(t) }.frame(width: drop, height: drop)
        }
        // No cancel button while working: the drop itself cancels, like pressing the shortcut again.
        .contentShape(Capsule())
        .onTapGesture { if cancellable { model.cancel?() } }
        .overlay(alignment: .topTrailing) { closeBadge }
        .scaleEffect(model.presented ? 1 : 0.35, anchor: dropAnchor)
        .opacity(model.presented ? 1 : 0)
        .padding(14 * scale)
        // Exit: collapse into the drop first, then shrink out from its centre.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : model.presented ? .spring(duration: 0.45, bounce: 0.3) : .easeIn(duration: 0.22).delay(0.2),
                   value: model.presented)
        .onChange(of: model.phase) { _, phase in if phase == .working { start = Date() }; morph() }
        .onChange(of: model.label) { morph() }
        .onChange(of: model.presented) { _, presented in
            if presented { shown = drop; morph() } else { morph(collapse: true) }
        }
        .help(cancellable ? "Cancel correction · " + ShortcutSettings.shared.label(.correct) : model.detail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.label.isEmpty ? "Correction started" : model.label)
        .accessibilityValue(expanded ? model.detail : "")
        .accessibilityHidden(!model.presented)
        .accessibilityActions {
            if cancellable { Button("Cancel correction") { model.cancel?() } }
            if closable { Button("Dismiss") { model.dismiss?() } }
        }
    }

    /// Stretching unveils the label as the glass grows; shrinking narrows back into the drop.
    private func morph(collapse: Bool = false) {
        let target = collapse ? drop : width
        model.width = target
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : target > shown ? .spring(duration: 0.55, bounce: 0.16) : .spring(duration: 0.4, bounce: 0.1)) {
            shown = target
        }
    }

    /// Seconds into the working phase, at the display's refresh rate; paused otherwise.
    private func ticking(@ViewBuilder _ content: @escaping (Double) -> some View) -> some View {
        TimelineView(.animation(paused: reduceMotion || !working)) { context in content(context.date.timeIntervalSince(start)) }
    }

    /// The label is unveiled by the growing glass (clipped to it), not faded in on its own.
    private var label: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: drop - 6 * scale)
            // A new label replaces the old outright; a cross-fade would ghost "Fixing…" into the outcome.
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Capsule().fill(ink.opacity(0.4)).frame(width: 1.5 * scale, height: 11 * scale).frame(width: Self.divider * scale)
                    }
                    Text(part).font(Font(font)).lineLimit(1).fixedSize().contentTransition(.identity)
                }
            }
            .modifier(Halo(color: halo))
            if actionCount > 0 { Color.clear.frame(width: Self.gap * scale); actions }
        }
        .foregroundStyle(ink)
        // On exit the label fades before the glass narrows over it, rather than being cut off.
        .opacity(expanded && model.presented ? 1 : 0)
        .animation(.easeOut(duration: 0.2).delay(expanded ? 0.12 : 0), value: expanded)
        .animation(.easeOut(duration: 0.12), value: model.presented)
    }

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

    private func eyes(_ t: Double) -> some View {
        let pose = pose(t)
        // A done drop's eyes swing into a check, and relax back into the side-eye as it collapses.
        let check = [.fixed, .copied].contains(model.phase) && model.presented ? 1.0 : 0
        return DashEyes(look: pose.look, lid: pose.lid, check: check, ink: ink, halo: halo)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : check > 0 ? .spring(duration: 0.5, bounce: 0.32) : .spring(duration: 0.55, bounce: 0.15),
                       value: model.phase)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0), value: model.presented)
            .accessibilityHidden(true)
    }

    /// Look and lid (0 open … 1 closed) for each moment.
    private func pose(_ t: Double) -> (look: CGSize, lid: Double) {
        switch model.phase {
        case .invoked: return (towardText, 0.15)
        case .working:
            guard !reduceMotion else { return (towardText, 0.4) }
            return DashEyes.readingPose(t, toward: towardText)
        case .fixed, .copied: return (DashEyes.restingLook, DashEyes.restingLid) // unimpressed side-eye at the fixed draft
        case .failed, .pending: return DashEyes.failedPose // looking away, clear of the label
        case .reverted: return DashEyes.revertedPose // eyes rolled up
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .fixed where model.canRevert:
            button("arrow.uturn.backward", "Revert correction") { model.revert?() }
        case .pending, .copied:
            button(model.copied ? "checkmark" : "doc.on.doc", "Copy correction") { if !model.copied { model.copy?() } }
        case .failed:
            switch model.remedy {
            case .retry: button("arrow.clockwise", "Try again") { model.retry?() }
            case .settings: button("gearshape", "Open Settings") { model.openSettings?() }
            case nil: EmptyView()
            }
        default: EmptyView()
        }
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        DropActionButton(symbol: symbol, label: label, scale: scale, action: action)
    }
}

/// Mask for the glass: solid at the rim, feathered to `center` inside, so the drop thins out
/// toward its middle with no visible inner edge. Native frost cannot be tuned; this can.
private struct FeatheredCapsule: View {
    let center: Double
    var body: some View {
        GeometryReader { proxy in
            let inset = proxy.size.height * 0.2
            ZStack {
                Capsule().fill(.white)
                Capsule().inset(by: inset).fill(.white.opacity(1 - center))
                    .blur(radius: inset * 0.8).blendMode(.destinationOut)
            }
            // Rasterized once: as a live filter chain, the blur re-ran on every frame of a moving backdrop.
            .drawingGroup()
            .clipShape(Capsule())
        }
    }
}

/// Only what real glass shows: a faint sheen across the top, a hairline edge brighter where the
/// light is, a soft pool of refracted light inside the lower edge, a hairline of dispersion at
/// the rim and, while working, a soft colourless highlight travelling slowly round the edge.
private struct GlassLight: View {
    let t: Double, travelling: Bool, dark: Bool
    private static let warm = Color(red: 1, green: 0.5, blue: 0.32), cool = Color(red: 0.35, green: 0.72, blue: 1)
    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            ZStack {
                LinearGradient(colors: [.white.opacity(dark ? 0.17 : 0.22), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5))
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.55 : 0.7), .white.opacity(0.08), .white.opacity(dark ? 0.2 : 0.3)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                // Refraction: light focused through the drop pools softly inside its lower edge.
                Capsule().strokeBorder(LinearGradient(colors: [.clear, .white.opacity(dark ? 0.16 : 0.24)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom),
                                       lineWidth: h * 0.07)
                    .blur(radius: h * 0.03).padding(h * 0.05)
                // Dispersion: the rim splits the light a touch, warm on one side, cool on the other,
                // each fringe nudged apart the way red and blue bend by different amounts.
                Capsule().strokeBorder(LinearGradient(colors: [.clear, .clear, Self.warm.opacity(dark ? 0.45 : 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                       lineWidth: 1.1)
                    .offset(x: 0.4, y: 0.5).blur(radius: 0.35)
                Capsule().strokeBorder(LinearGradient(colors: [Self.cool.opacity(dark ? 0.45 : 0.5), .clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                                       lineWidth: 1.1)
                    .offset(x: -0.4, y: -0.5).blur(radius: 0.35)
                if travelling {
                    // Light catching the edge as the drop turns: soft, white, about a lap every 1.8 s.
                    Circle().trim(from: 0, to: 0.16)
                        .stroke(AngularGradient(colors: [.white.opacity(0), .white.opacity(dark ? 0.75 : 0.95), .white.opacity(0)], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(58)),
                                style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: h - 1.6, height: h - 1.6)
                        .rotationEffect(.radians(t * 3.5 - .pi / 2))
                        .blur(radius: 0.7)
                        .frame(width: h, height: h)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .clipShape(Capsule())
            // One cached bitmap rather than blurred strokes re-filtered on each composite over a moving backdrop.
            .drawingGroup()
        }
        .allowsHitTesting(false)
    }
}
