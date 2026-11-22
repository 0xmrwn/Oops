import CoreGraphics

public enum WheelPlacement {
    /// The hub in AX points: where Fix's drop would sit by the caret, then away from the text by half the envelope,
    /// the whole envelope kept on the screen. With no caret, Fix's fallbacks (composer, window, screen).
    public static func hub(_ geometry: CapsulePlacement.Geometry?, screens: [CGRect]) -> CGPoint {
        let size = WheelLayout.envelope, drop = WheelLayout.drop
        // Fix's drop's spot, tested for the wheel's height so it opens below the caret only when it fits there.
        let spot = CapsulePlacement.place(geometry, envelope: CGSize(width: drop, height: size.height), screens: screens)
        let x: CGFloat = switch spot.corner {
        case .topLeading, .bottomLeading: spot.envelope.minX + drop / 2
        case .topTrailing, .bottomTrailing: spot.envelope.maxX - drop / 2
        case .top, .bottom: spot.envelope.midX
        }
        let wheel = CGRect(x: x - size.width / 2, y: spot.envelope.minY, width: size.width, height: size.height)
        let bounds = CapsulePlacement.bestScreen(for: wheel, in: screens).insetBy(dx: 8, dy: 8)
        let kept = CapsulePlacement.clamp(wheel, into: bounds)
        return CGPoint(x: kept.midX, y: kept.midY)
    }
}
