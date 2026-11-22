import SwiftUI

/// Only what real glass shows: a faint sheen across the top, a hairline edge brighter where the
/// light is, a soft pool of refracted light inside the lower edge, a hairline of dispersion at
/// the rim and, while working, a soft colourless highlight travelling slowly round the edge.
struct GlassLight: View {
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
