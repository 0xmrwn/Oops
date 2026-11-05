// Composites the window as Finder would show the mounted DMG, in light and dark appearance, without
// opening Finder: swift design/dmg/preview.swift <icon-directory> (render.sh supplies the icons).
// Also prints how Finder's label ink contrasts with the background under the labels.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let here = root.appendingPathComponent("design/dmg")
let icons = URL(fileURLWithPath: CommandLine.arguments[1])
let content = CGSize(width: 640, height: 400), titlebar: CGFloat = 28, margin: CGFloat = 56, scale: CGFloat = 2
let app = CGPoint(x: 160, y: 176), folder = CGPoint(x: 480, y: 176), iconSize: CGFloat = 128, textSize: CGFloat = 13
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

struct Look {
    let name: String, appearance: NSAppearance, desk: [NSColor], bar: NSColor, separator: NSColor, border: NSColor, shadow: CGFloat, appIcon: String
}

let looks = [
    Look(name: "light", appearance: NSAppearance(named: .aqua)!, desk: [rgb(0xE4E8ED), rgb(0xC9D0D8)], bar: rgb(0xF4F4F5),
         separator: NSColor(white: 0, alpha: 0.10), border: NSColor(white: 0, alpha: 0.22), shadow: 0.28, appIcon: "Default"),
    Look(name: "dark", appearance: NSAppearance(named: .darkAqua)!, desk: [rgb(0x2A2D33), rgb(0x16181B)], bar: rgb(0x2C2C2E),
         separator: NSColor(white: 0, alpha: 0.55), border: NSColor(white: 1, alpha: 0.16), shadow: 0.6, appIcon: "Dark"),
]

/// Relative luminance (WCAG) of an sRGB pixel.
func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
}

/// Worst-case contrast of Finder's label ink (black or white at 85%) over the label band below an icon.
func labelContrast(_ background: CGImage, under center: CGPoint, ink: CGFloat) -> CGFloat {
    let width = background.width, height = background.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
    var worst = CGFloat.infinity
    let top = center.y + iconSize / 2 + 4
    for y in stride(from: top, to: top + 18, by: 1) {
        for x in stride(from: center.x - 42, to: center.x + 42, by: 1) {
            let index = (Int(y * scale) * width + Int(x * scale)) * 4 // Row 0 is the top.
            let color = (0..<3).map { CGFloat(pixels[index + $0]) / 255 }
            func over(_ c: CGFloat) -> CGFloat { ink * 0.85 + c * 0.15 }
            let text = luminance(over(color[0]), over(color[1]), over(color[2]))
            let field = luminance(color[0], color[1], color[2])
            worst = min(worst, (max(text, field) + 0.05) / (min(text, field) + 0.05))
        }
    }
    return worst
}

func label(_ text: String, below center: CGPoint, offset: CGPoint) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: textSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    let rect = NSRect(x: offset.x + center.x - 70, y: offset.y + center.y + iconSize / 2 + 3, width: 140, height: textSize + 6)
    (text as NSString).draw(in: rect, withAttributes: attributes)
}

func render(look: Look) throws {
    let background = NSImage(contentsOf: here.appendingPathComponent("background@2x.png"))!
    background.size = content
    let appIcon = NSImage(contentsOf: icons.appendingPathComponent("icon-\(look.appIcon).png"))!
    let folderIcon = NSWorkspace.shared.icon(forFile: "/Applications")
    let alias = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns")!
    let size = CGSize(width: content.width + margin * 2, height: content.height + titlebar + margin * 2)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    let cg = context.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    look.appearance.performAsCurrentDrawingAppearance {
        NSGradient(starting: look.desk[0], ending: look.desk[1])!.draw(in: NSRect(origin: .zero, size: size), angle: 90)
        let frame = NSRect(x: margin, y: margin, width: content.width, height: content.height + titlebar)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: look.shadow)
        shadow.shadowBlurRadius = 36
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.set()
        look.bar.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        look.bar.setFill()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: titlebar).fill()
        let origin = CGPoint(x: frame.minX, y: frame.minY + titlebar)
        background.draw(in: NSRect(origin: origin, size: content), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        look.separator.setFill()
        NSRect(x: frame.minX, y: origin.y - 0.5, width: frame.width, height: 0.5).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (index, color) in [rgb(0xFF5F57), rgb(0xFEBC2E), rgb(0x28C840)].enumerated() {
            let light = NSBezierPath(ovalIn: NSRect(x: frame.minX + 14 + CGFloat(index) * 20, y: frame.minY + 8, width: 12, height: 12))
            color.setFill()
            light.fill()
            NSColor(white: 0, alpha: 0.12).setStroke()
            light.lineWidth = 0.5
            light.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        ("Oops" as NSString).draw(in: NSRect(x: frame.minX, y: frame.minY + 6, width: frame.width, height: 18),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        for (icon, center) in [(appIcon, app), (folderIcon, folder)] {
            let rect = NSRect(x: origin.x + center.x - iconSize / 2, y: origin.y + center.y - iconSize / 2, width: iconSize, height: iconSize)
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if icon === folderIcon { alias.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        }
        label("Oops", below: app, offset: origin)
        label("Applications", below: folder, offset: origin)
        look.border.setStroke()
        let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: 16, yRadius: 16)
        edge.lineWidth = 0.5
        edge.stroke()
    }
    NSGraphicsContext.current = nil
    try bitmap.representation(using: .png, properties: [:])!.write(to: here.appendingPathComponent("preview-\(look.name).png"))
}

for look in looks { try render(look: look) }
let background = NSBitmapImageRep(data: try Data(contentsOf: here.appendingPathComponent("background@2x.png")))!.cgImage!
let black = min(labelContrast(background, under: app, ink: 0), labelContrast(background, under: folder, ink: 0))
let white = min(labelContrast(background, under: app, ink: 1), labelContrast(background, under: folder, ink: 1))
print(String(format: "Worst label contrast %.1f:1 light (black ink), %.1f:1 dark (white ink)", black, white))
