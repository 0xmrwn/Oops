import AppKit
import SwiftUI

/// Native vector lettering, with the same live character used by the correction drop.
struct BrandWordmark: View {
    var look = DashEyes.restingLook
    var lid = DashEyes.restingLid
    var ink: Color = .primary
    var glass = false
    var showCharacter = true

    private nonisolated static let size = CGSize(width: 237, height: 88.75198364257812)
    private nonisolated static let character = CGRect(x: 0.8045196533203125, y: 0, width: 72.86529541015625, height: 72.86529541015625)

    nonisolated static func characterFrame(width: CGFloat) -> CGRect {
        character.applying(CGAffineTransform(scaleX: width / size.width, y: width / size.width))
    }

    /// The O's heavier rim leaves less travel than the clear drop. Keep even a diagonal gaze clear
    /// of its counter, preserving the approved resting pose and optical placement.
    nonisolated static func characterLook(_ look: CGSize) -> CGSize {
        CGSize(width: min(max(look.width, -0.9), 0.55) + 3 / character.width * 32 / 4.5,
               height: min(max(look.height, -0.45), 0.45) - 2 / character.height * 32 / 3.5)
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = Self.characterFrame(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                if glass, showCharacter {
                    Color.clear.frame(width: frame.width, height: frame.height)
                        .glassEffect(.clear, in: .circle)
                        .position(x: frame.midX, y: frame.midY)
                }
                Image(nsImage: BrandAssets.image("OopsLettering"))
                    .resizable().renderingMode(.template).foregroundStyle(ink)
                    .mask(alignment: .leading) {
                        if showCharacter { Rectangle() } else {
                            HStack(spacing: 0) { Color.clear.frame(width: frame.maxX); Rectangle() }
                        }
                    }
                // Optical clearance inside the heavier O, measured in the lettering's 100 pt space.
                DashEyes(look: Self.characterLook(look), lid: lid, ink: ink, halo: .clear)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(showCharacter ? 1 : 0)
            }
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Oops")
    }
}

/// The approved O's counter travels with its eyes, then dissolves into the clear setup drop.
struct BrandCharacterRim: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        path.addEllipse(in: rect.insetBy(dx: rect.width * 12.371 / 72.86529541015625,
                                        dy: rect.height * 9.839 / 72.86529541015625))
        return path
    }
}

/// The drop keeps its glass body in Settings; blinking changes only the eyes.
struct CompanionDrop: View {
    var look = DashEyes.restingLook
    var lid = DashEyes.restingLid
    var ink: Color = .primary

    var body: some View {
        Color.clear
            .glassEffect(.clear, in: .circle)
            .overlay { DashEyes(look: look, lid: lid, ink: ink, halo: .clear) }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

@MainActor enum BrandAssets {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage {
        if let image = images[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else { preconditionFailure("Missing bundled brand asset: \(name)") }
        image.isTemplate = true
        images[name] = image
        return image
    }
}
