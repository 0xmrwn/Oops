import AppKit
import ImageIO

/// The in-window app mark, decoded once per appearance at the size windows show it. Loading the
/// 1024 px PNG in a view body decoded it again on every redraw, every frame of a transition.
@MainActor enum AppIcon {
    private static var cache: [Bool: NSImage] = [:]

    /// Sharp up to 64 pt on a 2x display.
    static func image(dark: Bool) -> NSImage? {
        if let image = cache[dark] { return image }
        guard let url = Bundle.main.url(forResource: dark ? "OopsIcon-dark" : "OopsIcon", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: 64, height: 64))
        cache[dark] = image
        return image
    }
}
