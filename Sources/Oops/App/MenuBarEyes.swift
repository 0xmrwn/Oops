import AppKit

/// The wordmark's character, optically fitted to the status bar. AppKit supplies its ink.
@MainActor enum MenuBarEyes {
    static func configure(_ button: NSStatusBarButton) {
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Oops"
        button.setAccessibilityLabel("Oops")
        button.setAccessibilityHelp("Open Oops menu")
    }

    static let image: NSImage = {
        let mark = BrandAssets.image("OopsMenuBar")
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            mark.draw(in: NSRect(x: 3, y: 1, width: 16, height: 16))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Oops"
        return image
    }()
}
