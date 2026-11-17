#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// Debug builds only: `-DictationDropProbe light|dark|grey` shows the real dictation drop, in its floating panel,
/// over a plain window standing in for a page of that colour whose field reports its text colour, driven by the
/// synthetic voice through listening, transcribing and written on a loop. `-DictationDropProbeGlass app` keeps the
/// field's colour from the drop, so its glass follows the system as before. It shows the panel's glass over another
/// window as it sits over another app, which the lab's in-window glass cannot.
@MainActor final class DictationDropProbe {
    private let owner = DropOwner()
    private let feed = DictationLoudnessFeed()
    private var page: NSWindow?
    private var drop: DictationDropOwner?
    private var timer: Timer?
    private var shown: DictationDropState?

    func show(_ kind: String) {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.minX + 80, y: visible.maxY - 440, width: 640, height: 380)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Page"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProbePage(kind: kind))
        NSApp.enterDock()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        page = window
        // In screen coordinates from the top, as Accessibility reports them: a field across the page's lower half.
        let top = screen.frame.height - window.frame.maxY
        let field = CGRect(x: window.frame.minX + 40, y: top + 190, width: window.frame.width - 80, height: 120)
        let ink: SIMD3<Double> = kind == "dark" ? SIMD3(0.92, 0.92, 0.94) : SIMD3(0.1, 0.1, 0.12)
        let style = DebugFlags.dictationDropProbeGlass == "app" ? nil : CaretStyle(color: ink)
        let geometry = CapsulePlacement.Geometry(element: field, window: CGRect(x: window.frame.minX, y: top, width: window.frame.width,
                                                                                   height: window.frame.height))
        let drop = DictationDropOwner(owner: owner, loudness: feed) { (geometry, style) }
        self.drop = drop
        let start = Date().timeIntervalSinceReferenceDate
        feed.start {
            let level = Double(SyntheticLoudness.level(at: Date().timeIntervalSinceReferenceDate - start))
            guard level > 0 else { return 0 }
            let decibels = Double(DictationLoudness.floorDBFS) + level * Double(DictationLoudness.ceilingDBFS - DictationLoudness.floorDBFS)
            return Float(pow(10, decibels / 20))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(Date().timeIntervalSinceReferenceDate - start) }
        }
    }

    /// The lab's loop: listening through the voice's speech, then transcribing, then written.
    private func step(_ time: Double) {
        let state: DictationDropState = switch time.truncatingRemainder(dividingBy: SyntheticLoudness.period) {
        case ..<10.2: .recording
        case ..<11.3: .transcribing
        default: .written
        }
        guard state != shown, let drop else { return }
        shown = state
        if state == .recording { _ = drop.claim { true } }
        drop.show(state)
    }
}

/// A page of one colour with a paragraph and a field's worth of text, in the colour its field reports.
private struct ProbePage: View {
    let kind: String

    var body: some View {
        let dark = kind == "dark"
        ZStack(alignment: .topLeading) {
            kind == "grey" ? Color(white: 0.6) : dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white
            Text("Hi Sam, thanks for sending the deck over. I went through the numbers this morning and I think we should move the review to Friday so")
                .font(.system(size: 15)).lineSpacing(4).padding(40)
                .foregroundStyle(dark ? Color(white: 0.92) : Color(white: 0.1))
        }
    }
}
#endif
