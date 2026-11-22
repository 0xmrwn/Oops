#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// The menu bar eyes with an agent run's marks (none, running, ready), at the bar's size and magnified, on a light and a
/// dark bar, for reviewing them without a run.
@MainActor enum MenuBarMarkSnapshots {
    static func render(to directory: URL) {
        for (name, dark) in [("light", false), ("dark", true)] {
            let ink: Color = dark ? .white : .black
            let marks: [AgentRunFlow.MenuMark] = [.none, .running, .ready]
            let view = VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ForEach(marks.indices, id: \.self) { index in
                        Image(nsImage: MenuBarEyes.image(marks[index])).renderingMode(.template).foregroundStyle(ink)
                            .frame(width: 22, height: 18)
                    }
                }
                HStack(spacing: 24) {
                    ForEach(marks.indices, id: \.self) { index in
                        Image(nsImage: MenuBarEyes.image(marks[index])).renderingMode(.template).resizable().interpolation(.none)
                            .foregroundStyle(ink).frame(width: 88, height: 72)
                    }
                }
            }
            .padding(16)
            .background(Color(white: dark ? 0.16 : 0.93))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: directory.appendingPathComponent("menubar-marks-\(name).png"))
        }
    }
}
#endif
