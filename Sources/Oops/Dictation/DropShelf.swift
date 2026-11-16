import SwiftUI

/// The dictation drop and the shelf its live words sit on, as one outline: the capsule alone while `open` is 0,
/// and at 1 a wider shelf grown out of the capsule's far side, its shoulders rounded into the capsule. One
/// shape, so the glass is one piece and the shelf opens out of the drop rather than beside it.
struct DropShelf: Shape {
    /// The shelf's width, and the height of the drop and its open shelf together.
    static let width: CGFloat = 340, height: CGFloat = 102
    /// How much of the capsule stands clear of the open shelf.
    private static let clear: CGFloat = 34

    var open: CGFloat
    /// The capsule's width; it sits centred on the shelf.
    var capsule: CGFloat
    /// The shelf is above the capsule, for a drop that hugs the bottom of its panel.
    let above: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(open, capsule) }
        set { open = newValue.first; capsule = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let drop = EyesDropView.drop, cap = drop / 2
        let near = rect.midX - capsule / 2, far = near + capsule
        // A spring may carry `open` a little past its ends.
        let open = min(max(open, 0), 1)
        func y(_ distance: CGFloat) -> CGFloat { above ? rect.maxY - distance : rect.minY + distance }
        guard open > 0.001 else {
            return Path(roundedRect: CGRect(x: near, y: min(y(0), y(drop)), width: capsule, height: drop), cornerRadius: cap)
        }
        // Everything is measured from the capsule's own edge and grows from the capsule's outline: at 0 the
        // shelf's corners are the capsule's far cap, so the two outlines are the same.
        let left = near + (rect.minX - near) * open, right = far + (rect.maxX - far) * open
        let shoulder = cap + (Self.clear - cap) * open, foot = drop + (rect.height - drop) * open
        let fillet = 9 * open, footCorner = cap - 7 * open, corner = min(16, max(0, right - far - fillet))
        let corners: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
            (near, 0, cap), (far, 0, cap), (far, shoulder, fillet), (right, shoulder, corner),
            (right, foot, footCorner), (left, foot, footCorner), (left, shoulder, corner), (near, shoulder, fillet),
        ]
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: y(0)))
        for index in 1 ... corners.count {
            let at = corners[index % corners.count], next = corners[(index + 1) % corners.count]
            let point = CGPoint(x: at.x, y: y(at.y))
            if at.radius < 0.01 {
                path.addLine(to: point)
            } else {
                path.addArc(tangent1End: point, tangent2End: CGPoint(x: next.x, y: y(next.y)), radius: at.radius)
            }
        }
        path.closeSubpath()
        return path
    }
}
