#if DEBUG
import AppKit
import SwiftUI

/// Offscreen native components, before hotkeys, providers or windows are installed.
@MainActor enum BrandSnapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = VStack(spacing: 26) {
                BrandWordmark().frame(width: 360)
                HStack(spacing: 36) {
                    if let icon = AppIcon.image(dark: scheme == .dark) {
                        Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                    }
                    if let dock = DockIcon.image(dark: scheme == .dark) {
                        Image(nsImage: dock).resizable().frame(width: 128, height: 128)
                    }
                    CompanionDrop().frame(width: 88, height: 88)
                    Image(nsImage: MenuBarEyes.image).renderingMode(.template)
                        .frame(width: 22, height: 18)
                }
                HStack(spacing: 16) {
                    BrandWordmark().frame(width: 144)
                    BrandWordmark(look: .zero, lid: 0).frame(width: 144)
                    BrandWordmark(look: CGSize(width: 1, height: 0), lid: 0).frame(width: 144)
                }
                HStack(spacing: 16) {
                    BrandWordmark(look: CGSize(width: -1, height: -1), lid: 0).frame(width: 144)
                    BrandWordmark(look: CGSize(width: 1, height: -1), lid: 0).frame(width: 144)
                    BrandWordmark(look: CGSize(width: -1, height: 1), lid: 0).frame(width: 144)
                }
            }
            .padding(36).frame(width: 600, height: 520)
            .background(Color(nsColor: scheme == .dark ? .black : .white))
            .foregroundStyle(scheme == .dark ? .white : .black)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Brand render failed") }
            try? data.write(to: directory.appendingPathComponent("brand-\(name).png"))
        }
    }
}
#endif
