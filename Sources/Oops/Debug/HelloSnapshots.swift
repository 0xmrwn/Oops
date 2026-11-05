#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `-HelloSnapshots <dir>` renders Hello's key moments to PNGs offscreen and exits,
/// before the app starts (no menu bar item, hotkeys or windows), so Hello's layout can be checked
/// without taking the screen or disturbing a running Oops. System glass may render flat here; motion
/// and glass are for a real run.
@MainActor enum HelloSnapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let moments: [(String, (HelloDirector) -> Void)] = [
            ("1-entrance", { director in
                director.seedShown = true; director.seedLid = 0; director.seedLook = .zero
                director.typed.typed = 0
            }),
            ("2-typing", { director in
                director.seedShown = true; director.seedMorphed = true; director.windowShown = true
                director.typed.typed = 26; director.typed.caret = true
            }),
            ("3-fixed", { director in
                director.windowShown = true; director.typed.typed = nil
                fix(director.typed)
            }),
            ("4-wave", { director in
                director.windowShown = true; director.zoomed = false; director.stage = .desktop
                director.typed.typed = nil; director.typed.corrected = true
                director.waiting.forEach { $0.shown = true; fix($0) }
            }),
            ("5-finale", { director in
                director.windowShown = true; director.zoomed = false; director.stage = .finale
                director.finaleLook = .zero; director.finaleLid = 0
            })
        ]
        for (name, set) in moments {
            let director = HelloDirector()
            director.waiting.forEach { $0.shown = false }
            set(director)
            let renderer = ImageRenderer(content: HelloScene(director: director) {}.frame(width: HelloZoom.stage.width, height: HelloZoom.stage.height).environment(\.colorScheme, .dark))
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try? png?.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private static func fix(_ state: HelloWindowState) {
        state.corrected = true; state.flash = 1
        state.drop.label = state.draft.label; state.drop.phase = .fixed; state.drop.presented = true
    }
}
#endif
