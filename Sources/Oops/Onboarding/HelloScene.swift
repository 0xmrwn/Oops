import SwiftUI

/// Hello's stage: a 1200 × 750 desktop scaled to the window. A ShaderGradient wallpaper shows through
/// Oops's own glass (the drops, the finale), which stays clear with white ink over the wallpaper.
///
/// The desktop is laid out at the camera's closest zoom (`HelloZoom`) and scaled down to pull back,
/// never up. The drops and the entrance's seed float above it, placed on their fields through
/// anchors, and are drawn natively at the camera's zoom, so they keep their size against the text.
struct HelloScene: View {
    let director: HelloDirector
    /// Set up was pressed: the finale's drop has gone on to the setup steps, and its pane fades away.
    var handedOff = false
    var visible = true
    let setUp: () -> Void
    private let canvas = HelloZoom.stage
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }
    private var blinking: Bool { visible && director.finaleReady && director.stage == .finale && !handedOff && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / canvas.width, proxy.size.height / canvas.height)
            stage
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(.black)
        .ignoresSafeArea()
        .task(id: blinking) {
            guard blinking else { return }
            try? await director.blink()
        }
        // The desktop is a recorded illustration, not a collection of usable apps and editors.
        .accessibilityRepresentation {
            if director.stage == .finale { Button("Set up", action: setUp) }
            else { Button("Skip introduction") { director.skip() } }
        }
    }

    private var stage: some View {
        let finale = director.stage == .finale
        return ZStack {
            // Never blurred behind the finale and the setup steps: only glass frosts.
            ShaderGradientView(visible: visible).scaleEffect(director.zoomed ? 1.07 : 1)
            if !director.desktopDismissed {
                world
                    .opacity(finale ? 0 : 1).blur(radius: finale ? 10 : 0)
                    .accessibilityHidden(finale)
            }
            HelloFinale(director: director, handedOff: handedOff, setUp: setUp)
                .opacity(finale && !handedOff ? 1 : 0).scaleEffect(finale || reduceMotion ? 1 : 0.6)
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.9, bounce: 0.3), value: finale)
                .animation(.easeOut(duration: 0.35), value: handedOff)
                .allowsHitTesting(finale && !handedOff)
        }
        .overlayPreferenceValue(HelloFieldsKey.self) { fields in
            if !director.desktopDismissed {
                GeometryReader { proxy in drops(fields, in: proxy) }.allowsHitTesting(false)
            }
        }
        .overlayPreferenceValue(HelloWindowKey.self) { window in
            if !director.desktopDismissed {
                GeometryReader { proxy in seed(window.map { proxy[$0] }) }.allowsHitTesting(false)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    /// The desktop at zoomed size, centred on the first window, scaled down by the pull-back.
    private var world: some View {
        ZStack(alignment: .topLeading) {
            ForEach(director.waiting) { state in
                window(state)
                    .opacity(state.shown ? 1 : 0)
                    .scaleEffect(state.shown || reduceMotion ? 1 : 0.94)
                    .offset(y: state.shown || reduceMotion ? 0 : u(14))
                    .accessibilityHidden(!state.shown)
            }
            window(director.typed, reportsBounds: true)
                // Resolves out of the stretched glass: a little soft and small, settling into place.
                .opacity(director.windowShown ? 1 : 0)
                .blur(radius: director.windowShown ? 0 : u(10))
                .scaleEffect(director.windowShown || reduceMotion ? 1 : 0.97)
                .accessibilityHidden(!director.windowShown)
        }
        .frame(width: canvas.width * HelloZoom.factor, height: canvas.height * HelloZoom.factor, alignment: .topLeading)
        .scaleEffect(director.zoomed ? 1 : 1 / HelloZoom.factor)
        .frame(width: canvas.width, height: canvas.height)
    }

    /// `reportsBounds` reads the window's own frame, before `position` makes it fill the desktop.
    private func window(_ state: HelloWindowState, reportsBounds: Bool = false) -> some View {
        let frame = state.draft.frame
        return app(state)
            .frame(width: u(frame.width), height: u(frame.height))
            .anchorPreference(key: HelloWindowKey.self, value: .bounds) { reportsBounds ? $0 : nil }
            .position(x: u(frame.midX), y: u(frame.midY))
    }

    /// The drop's size against the text: the real drop over 13-point text, at the camera's zoom.
    private var dropScale: CGFloat { (director.zoomed ? HelloZoom.factor : 1) * HelloZoom.window }

    @ViewBuilder private func app(_ state: HelloWindowState) -> some View {
        switch state.draft.app {
        case .chat: HelloChatApp(state: state)
        case .mail: HelloMailApp(state: state)
        case .doc: HelloDocApp(state: state)
        case .page: HelloPageApp(state: state)
        case .team: HelloTeamApp(state: state)
        case .note: HelloNoteApp(state: state)
        case .messenger: HelloMessengerApp(state: state)
        }
    }

    /// Each drop above its field's trailing corner (leading, right to left), growing away from the edge.
    private func drops(_ fields: [HelloDraft.App: Anchor<CGRect>], in proxy: GeometryProxy) -> some View {
        ForEach(director.all) { state in
            if let anchor = fields[state.id] {
                let field = proxy[anchor], rtl = state.draft.rightToLeft, k = dropScale, box = 320 * k
                EyesDropView(model: state.drop, scale: k)
                    .frame(width: box, height: 74 * k, alignment: rtl ? .leading : .trailing)
                    // The glass's edge on the field's corner (the view pads it by 14), its bottom just above.
                    .position(x: rtl ? field.minX - 14 * k + box / 2 : field.maxX + 14 * k - box / 2, y: field.minY - 27 * k)
            }
        }
    }

    /// The entrance's lone drop: it wakes at the first window's centre, then stretches into its outline
    /// while the window resolves inside it.
    @ViewBuilder private func seed(_ window: CGRect?) -> some View {
        if let window {
            let morphed = director.seedMorphed && !reduceMotion, k = dropScale
            let size = morphed ? window.size : CGSize(width: 46 * k, height: 46 * k), radius = morphed ? u(14) : 23 * k
            GlassEffectContainer {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .glassEffect(.clear, in: .rect(cornerRadius: radius))
            }
            .overlay {
                DashEyes(look: director.seedLook, lid: director.seedLid, ink: .white, halo: .black.opacity(0.3))
                    .frame(width: 46 * k, height: 46 * k)
                    // The eyes widen as the glass stretches, then go: the window takes their place. The
                    // delayed curve covers only their scale and fade; a plain `.animation(_:value:)` would
                    // also take over their position, leaving them at the stretching glass's corner.
                    .animation(.easeOut(duration: 0.35).delay(morphed ? 0.1 : 0)) {
                        $0.scaleEffect(morphed ? 1.5 : 1).opacity(morphed ? 0 : 1)
                    }
            }
            .scaleEffect(director.seedShown || reduceMotion ? 1 : 0.35)
            .opacity(director.seedShown && !director.windowShown ? 1 : 0)
            .position(x: window.midX, y: window.midY)
            .accessibilityHidden(true)
        }
    }
}

struct HelloWindowKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// A clear glass pane holding one large drop whose eyes follow the pointer, above Set up.
private struct HelloFinale: View {
    let director: HelloDirector
    let handedOff: Bool
    let setUp: () -> Void
    @State private var characterCenter = CGPoint.zero
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }
    var body: some View {
        GlassEffectContainer(spacing: 30) {
            VStack(spacing: 40) {
                // Once handed off, the window draws this drop where it stood and carries it to the step.
                BrandWordmark(look: director.finaleLook, lid: director.finaleLid, ink: .white, glass: true, showCharacter: !handedOff)
                    .frame(width: 380)
                    .overlay {
                        GeometryReader { proxy in
                            let frame = BrandWordmark.characterFrame(width: proxy.size.width)
                            Color.clear.frame(width: frame.width, height: frame.height)
                                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["finale": $0] }
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                    .onGeometryChange(for: CGPoint.self) { proxy in
                        let origin = proxy.frame(in: .named("welcome-stage")).origin
                        let frame = BrandWordmark.characterFrame(width: proxy.size.width)
                        return CGPoint(x: origin.x + frame.midX, y: origin.y + frame.midY)
                    } action: { characterCenter = $0 }
                    .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: director.finaleLook)
                    .animation(nil, value: handedOff)
                    .accessibilityHidden(true)
                // The arrow says the setup starts here, not a settings page.
                OnboardingNextButton(title: "Set up", action: setUp)
            }
            .padding(.vertical, 58).frame(width: 500)
            .glassEffect(.clear, in: .rect(cornerRadius: 30))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "welcome-stage")
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location): director.look(at: CGSize(width: location.x - characterCenter.x, height: location.y - characterCenter.y))
            case .ended: director.look(at: nil)
            }
        }
    }
}
