// Rebuild the approved native vector assets: swift design/branding/export.swift
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/Brand", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let font = NSFont.systemFont(ofSize: 100, weight: .semibold)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Oops", attributes: [.font: font]))
var outlines: [CGPath] = []
var positions: [CGPoint] = []
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var points = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: count), &points)
    for index in 0..<count {
        guard let path = CTFontCreatePathForGlyph(font as CTFont, glyphs[index], nil) else { fatalError("Missing wordmark glyph") }
        outlines.append(path)
        positions.append(points[index])
    }
}
guard outlines.count == 4 else { fatalError("Expected four wordmark glyphs") }
let bounds = outlines[0].boundingBoxOfPath
guard abs(bounds.height - 72.8653) < 0.02 else { fatalError("System lettering changed; review before replacing the approved assets") }
let diameter = bounds.height
let center = CGPoint(x: bounds.midX, y: bounds.midY)
let circle = CGRect(x: center.x - diameter / 2, y: bounds.minY, width: diameter, height: diameter)
let wordBounds = CGRect(x: 0, y: -17.08984375, width: 237, height: 88.75198364257812)
// Side and top/bottom weights measured from the adjacent lowercase o's outline.
let rim = CGMutablePath()
rim.addEllipse(in: circle)
rim.addEllipse(in: circle.insetBy(dx: 12.371, dy: 9.839))
let lettering = CGMutablePath()
lettering.addPath(rim)
for index in 1..<outlines.count {
    lettering.addPath(outlines[index], transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
}

func eyes() -> CGPath {
    let result = CGMutablePath()
    let unit = diameter / 32
    let transform = CGAffineTransform(a: unit, b: 0, c: 0, d: -unit, tx: circle.minX + 3, ty: circle.maxY + 2)
    for (dx, height) in [(-3.3, 11.5), (3.3, 9.0)] {
        let x = 16 - 0.9 * 4.5 + dx
        let bottom = 16 + 0.35 * 3.5 + height / 2 + (dx < 0 ? 0.7 : 0)
        let cut = bottom - height + height * 0.75 * 0.55
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: x - 1.9, y: cut))
        eye.addLine(to: CGPoint(x: x + 1.9, y: cut))
        eye.addLine(to: CGPoint(x: x + 1.9, y: bottom - 1.9))
        eye.addArc(center: CGPoint(x: x, y: bottom - 1.9), radius: 1.9, startAngle: 0, endAngle: .pi, clockwise: false)
        eye.closeSubpath()
        result.addPath(eye, transform: transform)
    }
    return result
}

func svgPath(_ path: CGPath) -> String {
    var value = ""
    func n(_ number: CGFloat) -> String { String(format: "%.5f", Double(number)) }
    path.applyWithBlock { pointer in
        let element = pointer.pointee, p = element.points
        switch element.type {
        case .moveToPoint: value += "M\(n(p[0].x)) \(n(p[0].y))"
        case .addLineToPoint: value += "L\(n(p[0].x)) \(n(p[0].y))"
        case .addQuadCurveToPoint: value += "Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))"
        case .addCurveToPoint: value += "C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))"
        case .closeSubpath: value += "Z"
        @unknown default: fatalError("Unknown path element")
        }
    }
    return value
}

func export(_ name: String, path: CGPath, bounds: CGRect) throws {
    var page = CGRect(origin: .zero, size: bounds.size)
    let url = output.appendingPathComponent(name + ".pdf")
    guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
        fatalError("Cannot create vector PDF")
    }
    context.beginPDFPage(nil)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.addPath(path)
    context.drawPath(using: .eoFill)
    context.endPDFPage()
    context.closePDF()
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(bounds.width)" height="\(bounds.height)" viewBox="0 0 \(bounds.width) \(bounds.height)">
    <path transform="translate(\(-bounds.minX) \(bounds.maxY)) scale(1 -1)" d="\(svgPath(path))" fill="#000" fill-rule="evenodd"/>
    </svg>
    """
    try svg.write(to: output.appendingPathComponent(name + ".svg"), atomically: true, encoding: .utf8)
}

let face = eyes()
let wordmark = CGMutablePath()
wordmark.addPath(lettering)
wordmark.addPath(face)
let mark = CGMutablePath()
mark.addPath(rim)
mark.addPath(face)
try export("OopsWordmark", path: wordmark, bounds: wordBounds)
try export("OopsLettering", path: lettering, bounds: wordBounds)
try export("OopsMark", path: mark, bounds: circle)

// A display O's rim overwhelms the eyes in the status bar. This optical master keeps the
// flat lids, unequal lengths and Closer spacing, with enough ink for a 1× menu bar.
let menu = CGMutablePath()
menu.addEllipse(in: CGRect(x: 0, y: 0, width: 16, height: 16))
menu.addEllipse(in: CGRect(x: 1.5, y: 1.3, width: 13, height: 13.4))
for (x, height) in [(5.75, 4.5), (9.05, 3.5)] {
    let bottom = 9 - height
    menu.move(to: CGPoint(x: x - 1, y: 9))
    menu.addLine(to: CGPoint(x: x + 1, y: 9))
    menu.addLine(to: CGPoint(x: x + 1, y: bottom + 1))
    menu.addArc(center: CGPoint(x: x, y: bottom + 1), radius: 1, startAngle: 0, endAngle: .pi, clockwise: true)
    menu.closeSubpath()
}
try export("OopsMenuBar", path: menu, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))

// The icon and wordmark share optical placement, rather than maintaining a second face drawing.
let iconScale = 738 / diameter
let iconFace = CGMutablePath()
iconFace.addPath(face, transform: CGAffineTransform(a: iconScale, b: 0, c: 0, d: iconScale,
                                                  tx: 143 - circle.minX * iconScale, ty: 143 - circle.minY * iconScale))
let iconSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<path transform="translate(0 1024) scale(1 -1)" d="\(svgPath(iconFace))" fill="#17202b" fill-rule="evenodd"/>
</svg>
"""
try iconSVG.write(to: root.appendingPathComponent("Resources/Oops.icon/Assets/face.svg"), atomically: true, encoding: .utf8)
print("Exported native brand assets and shared icon face")
