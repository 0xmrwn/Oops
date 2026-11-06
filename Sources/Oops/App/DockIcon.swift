import AppKit

/// The Dock and Command-Tab icon while Oops has a Dock presence (Settings, onboarding). AppKit draws them from
/// `applicationIconImage`, which it loads once from the flat `Oops.icns`: the light rendition whatever the
/// theme, since an app that turns regular at run time doesn't get the asset catalog's dark one. So the icon is
/// set here from the light or dark mark and set again whenever the system appearance flips.
@MainActor enum DockIcon {
    /// Share of the canvas the shape covers in a macOS icon (204 of 256 in the compiled icns), centred.
    private static let body = 204.0 / 256
    private static var observation: NSKeyValueObservation?
    private static var cache: [Bool: NSImage] = [:]

    /// Sets the icon for the current theme now and on every theme change while Oops is in the Dock, and again on
    /// the next turn: the Dock loads the bundle's icon asynchronously once the app turns regular.
    static func refresh() {
        update()
        DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
        guard observation == nil else { return }
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
        }
    }

    static func releaseWhenAccessory() {
        guard NSApp.activationPolicy() == .accessory, !cache.isEmpty else { return }
        // AppKit keeps the current override even after the Dock tile disappears.
        NSApp.applicationIconImage = nil
        cache.removeAll()
    }

    private static func update() {
        guard NSApp.activationPolicy() == .regular else { return }
        // Clear and tinted icon styles are the system's to render from the asset catalog.
        let style = UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme") ?? ""
        guard !style.contains("Clear"), !style.contains("Tinted") else { return NSApp.applicationIconImage = nil }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = image(dark: dark)
    }

    /// The full-bleed mark inset to the icon grid, with a shadow like the system's.
    static func image(dark: Bool) -> NSImage? {
        if let image = cache[dark] { return image }
        // The mark ships at 1024 pixels. A 1024-point drawing handler can rasterize it
        // at 2048 pixels on Retina and keep those larger representations cached.
        let pixels = 1024
        guard let url = Bundle.main.url(forResource: dark ? "OopsIcon-dark" : "OopsIcon", withExtension: "png"),
              let mark = NSImage(contentsOf: url),
              let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        mark.cacheMode = .never
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let edge = CGFloat(pixels)
        let side = edge * body
        let inset = (edge - side) / 2
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = edge * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -edge * 0.01)
        shadow.set()
        mark.draw(in: NSRect(x: inset, y: inset, width: side, height: side))
        guard let bitmap = context.makeImage() else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: edge / 2, height: edge / 2))
        image.cacheMode = .never
        cache[dark] = image
        return image
    }
}
