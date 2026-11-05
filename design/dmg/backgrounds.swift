// Renders the DMG window's background at 1x and 2x: swift design/dmg/backgrounds.swift (from the
// repository root). Finder places the real icons and their labels on top; nothing here draws them.
//
// The joke, after Hex's installer: the window is full of faint, struck-out typos of the instruction,
// and the one line left clear under the icons is the instruction spelled right, as Oops would fix it.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let here = root.appendingPathComponent("design/dmg")
let window = CGSize(width: 640, height: 400)
// Icon centres, as layout.py's icon_locations: Finder hangs each label below its 128-point icon.
let app = CGPoint(x: 160, y: 176), folder = CGPoint(x: 480, y: 176)
// High enough to stay in view when the viewer's Finder shows its path and status bars (about 56 points).
let lineCenter: CGFloat = 316
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

func white(_ alpha: CGFloat) -> CGColor { CGColor(gray: 1, alpha: alpha) }

/// A top-left-origin point canvas at `scale`.
func canvas(_ scale: CGFloat) -> CGContext {
    let context = CGContext(data: nil, width: Int(window.width * scale), height: Int(window.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: window.height * scale)
    context.scaleBy(x: scale, y: -scale)
    context.interpolationQuality = .high
    return context
}

func vertical(_ context: CGContext, _ stops: [(CGFloat, CGColor)], in rect: CGRect) {
    let gradient = CGGradient(colorsSpace: srgb, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ context: CGContext, at center: CGPoint, radius: CGFloat, _ color: CGColor) {
    let clear = color.copy(alpha: 0)!
    let gradient = CGGradient(colorsSpace: srgb, colors: [color, clear] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// Typing slips, not misspellings anyone would defend: swapped, doubled, dropped and neighbouring keys.
let typos = [
    "Drga Oops to Applications", "Drag Oosp to Applications", "Darg Oops ot Applications", "Drag Ooops to Applicatoins",
    "Drag Oops to Aplications", "Drag Oops yo Applications", "Drsg Oops to Applciations", "Drag Opps to Applications",
    "drag oops too applications", "Drag Oops tp Appications", "Dragg Oops to Applicaitons", "Drag Oops to Applicatins",
    "Drag Oopd to Applications", "Drag Oops to Appliactions", "Drga Oosp ot Applicatoins", "Drag Ops to Applications",
    "Drag Oops to Apllications", "Drag Oops ti Applications", "Dag Oops to Applications", "Drag Oops to Applicationss",
]

/// The field of struck-out typos, drawn into its own layer so the clear places can be cut out of it.
func typoField(_ context: CGContext) {
    var seed: UInt64 = 0x0095
    func next(_ bound: Int) -> Int { // A fixed LCG, so every render is the same picture.
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(seed >> 33) % bound
    }
    let ink = NSColor(cgColor: white(0.12))!
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: ink,
        .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: ink,
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    for row in 0..<17 {
        var x = -CGFloat(next(220))
        while x < window.width {
            let text = NSAttributedString(string: typos[next(typos.count)], attributes: attributes)
            text.draw(at: CGPoint(x: x, y: 6 + CGFloat(row) * 23))
            x += text.size().width + 28
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// Clears an ellipse out of the layer: fully inside 62% of its radii, fading out to its edge.
func clear(_ context: CGContext, at center: CGPoint, radii: CGSize) {
    context.saveGState()
    context.setBlendMode(.destinationOut)
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: radii.width, y: radii.height)
    let gradient = CGGradient(colorsSpace: srgb, colors: [white(1), white(1), white(0)] as CFArray, locations: [0, 0.62, 1])!
    context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
    context.restoreGState()
}

// A graphite field, the eye's stroke laid on its side as the dashes of an arrow, and the typo joke.
func trail(_ context: CGContext) {
    let full = CGRect(origin: .zero, size: window)
    vertical(context, [(0, rgb(0x939CA7)), (0.5, rgb(0x77808B)), (0.69, rgb(0x67707C)), (1, rgb(0x5C6570))], in: full)
    radial(context, at: CGPoint(x: 320, y: 140), radius: 340, white(0.10))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    typoField(context)
    // The icons with their labels, the arrow, and the corrected line stay clear.
    clear(context, at: CGPoint(x: app.x, y: app.y + 18), radii: CGSize(width: 132, height: 116))
    clear(context, at: CGPoint(x: folder.x, y: folder.y + 18), radii: CGSize(width: 132, height: 116))
    clear(context, at: CGPoint(x: 322, y: app.y), radii: CGSize(width: 124, height: 74))
    clear(context, at: CGPoint(x: 320, y: lineCenter), radii: CGSize(width: 230, height: 40))
    context.endTransparencyLayer()
    // Each dash is an eye turned to face the folder: flat lid behind, round end leading.
    let thickness: CGFloat = 7, y = app.y, gap: CGFloat = 8, head: CGFloat = 18
    let lengths: [CGFloat] = [13, 10.2, 13, 10.2, 13] // The two eyes' 11.5 : 9, alternating.
    // Centred between the icons' artwork; the folder's has more inset than the app icon's.
    var x = 322 - (lengths.reduce(0, +) + gap * CGFloat(lengths.count) + head) / 2
    for (index, length) in lengths.enumerated() {
        let r = thickness / 2
        let dash = CGMutablePath()
        dash.move(to: CGPoint(x: x, y: y - r))
        dash.addLine(to: CGPoint(x: x + length - r, y: y - r))
        dash.addArc(center: CGPoint(x: x + length - r, y: y), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        dash.addLine(to: CGPoint(x: x, y: y + r))
        dash.closeSubpath()
        context.addPath(dash)
        context.setFillColor(white(0.34 + 0.12 * CGFloat(index)))
        context.fillPath()
        x += length + gap
    }
    let tip = CGPoint(x: x + head, y: y)
    context.setStrokeColor(white(0.92))
    context.setLineWidth(thickness)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addLines(between: [CGPoint(x: tip.x - 11, y: y - 12), tip, CGPoint(x: tip.x - 11, y: y + 12)])
    context.strokePath()
    // The instruction as Oops would leave it.
    let line = NSAttributedString(string: "Drag Oops to Applications.", attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor(cgColor: white(0.96))!,
    ])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    let size = line.size()
    line.draw(at: CGPoint(x: (window.width - size.width) / 2, y: lineCenter - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
}

for scale: CGFloat in [1, 2] {
    let context = canvas(scale)
    trail(context)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    bitmap.size = window // 72 and 144 dpi, which tiffutil -cathidpicheck expects.
    let file = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: here.appendingPathComponent(file))
}
print("Rendered the DMG background at 1x and 2x")
