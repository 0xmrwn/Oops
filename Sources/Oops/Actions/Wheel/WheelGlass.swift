import OopsCore
import SwiftUI

extension WheelPiece {
    var frame: CGRect { CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height) }

    /// The piece's outline: a capsule, or a neck's concave bridge.
    var path: Path {
        if case let .neck(angle, length, end, waist) = kind { return NeckShape(angle: angle, length: length, end: end, waist: waist).path(in: frame) }
        return Path(roundedRect: frame, cornerRadius: frame.height / 2)
    }
}

/// Fix's drop thins its glass toward the middle. Here the cut-outs are drawn per piece on an otherwise solid mask, so
/// the liquid necks between pieces are never masked away. With `fades` (Reduce Motion, where pieces cross-fade in
/// place rather than travel), the mask is each piece's own outline at its fade, since glass ignores opacity.
struct FeatherMask: View {
    let pieces: [WheelPiece]
    var holes = true
    var fades: [String: Double]?

    var body: some View {
        Canvas { context, size in
            if let fades {
                for piece in pieces { context.fill(piece.path, with: .color(.white.opacity(fades[piece.id] ?? 1))) }
            } else {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            }
            guard holes else { return }
            context.blendMode = .destinationOut
            for piece in pieces where piece.hole > 0.01 {
                let inset = piece.size.height * 0.2
                let rect = piece.frame.insetBy(dx: inset, dy: inset)
                guard rect.width > 1, rect.height > 1 else { continue }
                var layer = context
                layer.addFilter(.blur(radius: inset * 0.8))
                layer.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(.white.opacity(0.55 * piece.hole)))
            }
        }
    }
}

/// A liquid bridge: wide where it meets the two drops, narrow at its waist, turned to the petal's direction.
struct NeckShape: Shape {
    var angle: Double, length: Double, end: Double, waist: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 16
        func point(_ index: Int, _ sign: Double) -> CGPoint {
            let t = Double(index) / Double(steps), k = 2 * t - 1
            return CGPoint(x: (t - 0.5) * length, y: sign * (waist / 2 + (end - waist) / 2 * k * k))
        }
        path.move(to: point(0, -1))
        for index in 1...steps { path.addLine(to: point(index, -1)) }
        for index in (0...steps).reversed() { path.addLine(to: point(index, 1)) }
        path.closeSubpath()
        return path.applying(CGAffineTransform(rotationAngle: angle)).applying(CGAffineTransform(translationX: rect.midX, y: rect.midY))
    }
}

/// Fix's halo, doubled and held closer to the strokes: 14 pt words need more than the drop's two thick dashes.
/// At zero strength it is the drop's halo exactly.
struct TunedHalo: ViewModifier {
    let color: Color, strength: Double

    func body(content: Content) -> some View {
        if strength <= 0.01 {
            content.modifier(Halo(color: color.opacity(0.85)))
        } else {
            let s = min(1, strength)
            content.shadow(color: color.opacity(0.55 + 0.4 * s), radius: 0.4).shadow(color: color.opacity(0.35 + 0.55 * s), radius: 0.9)
                .shadow(color: color.opacity(min(0.85, 0.25 + 0.6 * strength)), radius: 1.6 + 0.6 * strength)
                .shadow(color: color.opacity(min(0.8, 0.4 * strength)), radius: 4 + 2.5 * strength)
        }
    }
}

/// Where the lens shows: full under a piece's content, gone before its edge.
struct LensMask: View {
    let pieces: [WheelPiece]
    let strength: Double
    var fades: [String: Double]?

    var body: some View {
        Canvas { context, _ in
            for piece in pieces where piece.lens > 0.01 {
                let rect = piece.frame
                let inset = rect.height * 0.2, inner = rect.insetBy(dx: inset, dy: inset)
                guard inner.width > 1, inner.height > 1 else { continue }
                var layer = context
                layer.addFilter(.blur(radius: rect.height * 0.13))
                let amount = min(1, strength * piece.lens) * (fades?[piece.id] ?? 1)
                layer.fill(Path(roundedRect: inner, cornerRadius: inner.height / 2), with: .color(.white.opacity(amount)))
            }
        }
    }
}

/// What glass shows over a bright surface. Below the glass, a soft contact shadow with the glass's own outline punched
/// out of it, so nothing dark sits under the glass; above it, the outer half of a hairline. Drawn for the union of the
/// pieces, so lines never cross inside merged glass.
struct EdgeShade: View {
    let pieces: [WheelPiece]
    let amount: Double, travel: Double
    let hairline: Bool
    var fades: [String: Double]?

    /// The centre steps back while petals are still joined to it; a petal comes in as it pinches off.
    private func weight(_ piece: WheelPiece) -> Double {
        let weight = switch piece.kind {
        case .centre: 1 - 0.9 * travel
        case .neck: 1.0
        default: min(1, piece.light)
        }
        return weight * (fades?[piece.id] ?? 1)
    }

    var body: some View {
        Canvas { context, _ in
            let shapes = pieces.map { ($0.path, weight($0)) }.filter { $0.1 > 0.01 }
            if hairline {
                for (path, weight) in shapes { context.stroke(path, with: .color(.black.opacity(0.2 * amount * weight)), lineWidth: 1.7) }
            } else {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 3.2))
                    layer.translateBy(x: 0, y: 1.6)
                    for (path, weight) in shapes { layer.fill(path, with: .color(.black.opacity(0.36 * amount * weight))) }
                }
            }
            context.blendMode = .destinationOut
            for (path, weight) in shapes { context.fill(path, with: .color(.black.opacity(min(1, weight * 1.6)))) }
        }
        .allowsHitTesting(false)
    }
}
