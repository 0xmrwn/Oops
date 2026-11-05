import SwiftUI

/// Two slight dashes, unequal like the icon's eyes (the left one taller). They slide together to
/// look; lids cut them flat across the top, like half-closed eyes: lowered, that reads as unimpressed.
/// A check is two strokes too: at `check` 1 the left dash becomes its short stroke and the right its long one.
struct DashEyes: View, Animatable {
    nonisolated static let restingLook = CGSize(width: -0.9, height: 0.35)
    nonisolated static let restingLid = 0.55
    nonisolated static let failedPose = (look: CGSize(width: -0.75, height: -0.35), lid: 0.62)
    nonisolated static let revertedPose = (look: CGSize(width: 0.1, height: -0.95), lid: 0.0)

    /// The same reading cadence in a correction drop and Settings' Try status.
    nonisolated static func readingPose(_ time: Double, toward: CGSize) -> (look: CGSize, lid: Double) {
        let p = time.truncatingRemainder(dividingBy: 1.8) / 1.8
        let read = p < 0.8 ? p / 0.8 : 1 - (p - 0.8) / 0.2
        let blink = max(0, 1 - abs(time - 0.9) / 0.09)
        return (CGSize(width: toward.width - 0.45 + 0.9 * read, height: toward.height), 0.4 + 0.6 * blink)
    }

    var look: CGSize, lid: Double
    var check: Double = 0
    var ink: Color = .white
    var halo: Color = .black.opacity(0.25)
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<Double, Double>> {
        get { .init(.init(look.width, look.height), .init(lid, check)) }
        set {
            look = CGSize(width: newValue.first.first, height: newValue.first.second)
            lid = newValue.second.first; check = newValue.second.second
        }
    }
    /// The check's strokes on the 32 pt face, from their free end to the shared vertex, and their weight.
    private static let strokes = [(CGPoint(x: 11.5, y: 16.35), CGPoint(x: 14.25, y: 19.1)), (CGPoint(x: 20.5, y: 12.2), CGPoint(x: 14.25, y: 19.1))]
    private static let checkWeight = 2.2
    var body: some View {
        Canvas { context, size in
            let unit = size.width / 32 // Proportions drawn for a 32 pt face.
            let center = CGPoint(x: size.width / 2 + look.width * 4.5 * unit, y: size.height / 2 + look.height * 3.5 * unit)
            let k = check
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
            for (index, (dx, height)) in [(-3.3, 11.5), (3.3, 9.0)].enumerated() {
                // Each dash is a round-capped stroke between its cap centres, so it can swing into the check.
                let width = mix(3.8, Self.checkWeight) * unit, full = height * unit, x = center.x + dx * unit
                let bottom = center.y + full / 2 + (dx < 0 ? 0.7 * unit : 0)
                let stroke = Self.strokes[index]
                let top = CGPoint(x: mix(x, stroke.0.x * unit), y: mix(bottom - full + 3.8 * unit / 2, stroke.0.y * unit))
                let end = CGPoint(x: mix(x, stroke.1.x * unit), y: mix(bottom - 3.8 * unit / 2, stroke.1.y * unit))
                var dash = Path { $0.move(to: top); $0.addLine(to: end) }
                    .strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
                let closed = min(max(lid, 0), 1) * (1 - k)
                if closed > 0.02 {
                    // The lid: a flat cut across the top, leaving a half-moon at most three quarters shut.
                    let lidY = bottom - full + full * 0.75 * closed
                    dash = dash.intersection(Path(CGRect(x: 0, y: lidY, width: size.width, height: size.height - lidY)))
                }
                context.fill(dash, with: .color(ink))
            }
        }
        .modifier(Halo(color: halo))
    }
}

/// A crisp edge, a glow and a wide soft falloff, hugging the glyphs: ink holds over glass of the
/// other tone the way the Lock Screen clock holds over any wallpaper, without a backing shape.
struct Halo: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content.shadow(color: color, radius: 0.5).shadow(color: color.opacity(0.75), radius: 1.8).shadow(color: color.opacity(0.4), radius: 5)
    }
}
