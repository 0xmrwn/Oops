import AppKit
import OopsCore
import QuartzCore
import SwiftUI

/// Ink that takes its tone from what is behind the drop rather than from the appearance: the backdrop,
/// blurred, drained of colour, inverted and pushed to black or white, shown only where the content it covers
/// has drawn. Oops reads no pixels for this; the window server does the work, through the backdrop layer the
/// system's own materials are made of. Those classes are private, so everything here is looked up by name
/// and the drop keeps the appearance's ink and its halo when any of it is missing.
struct BackdropInk: NSViewRepresentable {
    /// Whether this system has the pieces.
    static let isAvailable = BackdropInkView.backdropLayer(tones: nil) != nil
    /// How far the layer reaches past the content: its blur fades toward its own edges, which would thin the ink.
    static let reach: CGFloat = 24

    /// The ink's two ends, in place of black and white: `light` over a light backdrop, `dark` over a dark one.
    struct Tones: Equatable {
        let light: SIMD3<Float>, dark: SIMD3<Float>

        /// Hex's own palettes: warm while it listens (`cool` 0), cool for its shimmer (1).
        static func hex(cool: Float) -> Tones {
            func tone(_ isDark: Bool) -> SIMD3<Float> {
                let saturation = DotScopeTuning.hud.saturation
                let warm = DotScopePalette.tone(isDark: isDark, cool: false, saturation: saturation)
                return warm + (DotScopePalette.tone(isDark: isDark, cool: true, saturation: saturation) - warm) * cool
            }
            return Tones(light: tone(false), dark: tone(true))
        }
    }

    var tones: Tones?

    func makeNSView(context: Context) -> BackdropInkView { BackdropInkView(tones: tones) }
    func updateNSView(_ nsView: BackdropInkView, context: Context) { nsView.tones = tones }
}

final class BackdropInkView: NSView {
    var tones: BackdropInk.Tones? {
        didSet {
            guard tones != oldValue, let backdrop else { return }
            // New filters leave the layer empty until the window server has them, so a tone that glides
            // changes the two colours in place; only gaining or losing the tones rebuilds the chain.
            if let tones, oldValue != nil {
                backdrop.setValue(Self.colour(tones.dark - tones.light), forKeyPath: "filters.inkSpan.inputColor")
                backdrop.setValue(Self.colour(tones.light), forKeyPath: "filters.inkBase.inputColor")
            } else {
                backdrop.filters = Self.filters(tones: tones)
            }
        }
    }

    private let backdrop: CALayer?

    init(tones: BackdropInk.Tones?) {
        self.tones = tones
        backdrop = Self.backdropLayer(tones: tones)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        guard let backdrop, let layer else { return }
        // A sublayer, not the backing layer: AppKit's own layer for the view never shows a backdrop.
        if backdrop.superlayer == nil { layer.addSublayer(backdrop) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backdrop.frame = layer.bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func backdropLayer(tones: BackdropInk.Tones?) -> CALayer? {
        guard let type = NSClassFromString("CABackdropLayer") as? CALayer.Type, let filters = filters(tones: tones) else { return nil }
        let layer = type.init()
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(0.25, forKey: "scale") // A tone needs no detail, and a quarter of the pixels costs less.
        layer.filters = filters
        return layer
    }

    /// Nil when this system lacks one of them.
    private static func filters(tones: BackdropInk.Tones?) -> [NSObject]? {
        var filters = [
            filter("gaussianBlur", ["inputRadius": 10.0]), filter("colorSaturate", ["inputAmount": 0.0]),
            filter("colorInvert"), filter("colorContrast", ["inputAmount": 6.0]),
        ]
        if let tones {
            // Black to white becomes `light` to `dark`: each channel is `light + ink * (dark - light)`.
            filters += [filter("multiplyColor", ["name": "inkSpan", "inputColor": colour(tones.dark - tones.light)]),
                        filter("colorAdd", ["name": "inkBase", "inputColor": colour(tones.light)])]
        }
        return filters.contains { $0 == nil } ? nil : filters.compactMap(\.self)
    }

    private static func colour(_ value: SIMD3<Float>) -> CGColor {
        CGColor(srgbRed: CGFloat(value.x), green: CGFloat(value.y), blue: CGFloat(value.z), alpha: 1)
    }

    private static func filter(_ name: String, _ values: [String: Any] = [:]) -> NSObject? {
        let make = NSSelectorFromString("filterWithType:")
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type, type.responds(to: make),
              let filter = type.perform(make, with: name)?.takeUnretainedValue() as? NSObject else { return nil }
        for (key, value) in values {
            filter.setValue(value, forKey: key)
        }
        return filter
    }
}

/// A voice in the drop's ink. Hex keeps its colours, gliding from warm to cool with the drop's own animation
/// as the scope does; the others, and everything under Increase Contrast, take plain ink.
private struct VoiceInked: ViewModifier, Animatable {
    let on: Bool, coloured: Bool
    var cool: Float
    var animatableData: Float {
        get { cool }
        set { cool = newValue }
    }

    func body(content: Content) -> some View {
        content.backdropInk(on, tones: coloured ? .hex(cool: cool) : nil)
    }
}

extension EnvironmentValues {
    /// Whether the drop's marks are drawn in `BackdropInk`, and so need no halo.
    @Entry var backdropInked = false
}

extension View {
    func voiceInk(_ on: Bool, kind: DictationVisualizer, state: DictationDropState, increasedContrast: Bool = false) -> some View {
        modifier(VoiceInked(on: on, coloured: kind == .hex && state.isLive && !increasedContrast, cool: state == .recording ? 0 : 1))
    }

    /// Recolours what this view draws with `BackdropInk` when `on`, keeping its shape and opacity.
    @ViewBuilder func backdropInk(_ on: Bool, tones: BackdropInk.Tones? = nil) -> some View {
        if on {
            hidden().overlay { BackdropInk(tones: tones).padding(-BackdropInk.reach).mask { self } }
        } else {
            self
        }
    }
}
