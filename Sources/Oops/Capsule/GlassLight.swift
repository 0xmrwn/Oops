import SwiftUI

/// Only what real glass shows: a faint sheen across the top, a hairline edge brighter where the
/// light is, a soft pool of refracted light inside the lower edge, a hairline of dispersion at
/// the rim. The working drop's travelling highlight is `TravellingLight`, drawn over it.
struct GlassLight: View {
    let dark: Bool
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
            }
            .clipShape(Capsule())
            // One cached bitmap rather than blurred strokes re-filtered on each composite over a moving backdrop.
            .drawingGroup()
        }
        .allowsHitTesting(false)
    }
}

/// Light catching the edge as the drop turns: a soft, colourless arc travelling round the leading cap. On the round
/// drop it runs at the rim; on a wide one (`slot` 1) it keeps to a ring inside the eye slot, clear of the label.
/// `slot` animates with the drop's width, so the ring draws in as the glass stretches.
struct TravellingLight: View, Animatable {
    /// The arc's angle in radians, its peak opacity, and the drop's height.
    let angle: Double, brightness: Double, size: CGFloat, scale: CGFloat
    var slot: Double
    var animatableData: Double {
        get { slot }
        set { slot = newValue }
    }

    var body: some View {
        let k = CGFloat(slot), rim = size - 1.6
        Circle().trim(from: 0, to: 0.16)
            .stroke(AngularGradient(colors: [.white.opacity(0), .white.opacity(brightness), .white.opacity(0)], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(58)),
                    style: StrokeStyle(lineWidth: 1.6 + (1.8 * scale - 1.6) * k, lineCap: .round))
            .frame(width: rim + (34 * scale - rim) * k, height: rim + (34 * scale - rim) * k)
            .rotationEffect(.radians(angle - .pi / 2))
            .blur(radius: 0.7)
            .frame(width: size, height: size)
    }
}

/// Mask for the glass: solid at the rim, feathered to `center` inside, so the drop thins out
/// toward its middle with no visible inner edge. Native frost cannot be tuned; this can.
struct FeatheredCapsule: View {
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
