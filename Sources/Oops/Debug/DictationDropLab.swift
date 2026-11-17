#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// The dictation drop with each voice visualizer, over a light text area, a dark one, a grey one and a busy one,
/// driven by `SyntheticLoudness` rather than a microphone, so each can be watched and recorded. Each cell is the
/// real drop's capsule (`DictationCapsule`) in regular glass, without the panel and the shelf around it.
@MainActor final class DictationDropLab: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        let view = DictationDropLabBoard { [weak self] dark in
            self?.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        let window = FocusRingsWindow(contentViewController: NSHostingController(rootView: view.focusRingsFromKeyboard()))
        window.title = "Oops · dictation drop"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // On the primary display, whole: Hex's Metal layer shows in a capture of the screen, not of the window.
        if let screen = NSScreen.screens.first {
            window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 20))
        }
        self.window = window
        NSApp.enterDock()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

private enum LabPhase: String, CaseIterable {
    /// Listening through the curve's speech, then transcribing and written through its closing silence.
    case auto, listening, transcribing, cleaningUp = "cleaning-up", written, failed

    var title: String { self == .cleaningUp ? "Cleaning up" : rawValue.capitalized }

    func state(at time: Double) -> DictationDropState {
        switch self {
        case .auto:
            switch time.truncatingRemainder(dividingBy: SyntheticLoudness.period) {
            case ..<10.2: .recording
            case ..<11.3: .transcribing
            default: .written
            }
        case .listening: .recording
        case .transcribing: .transcribing
        case .cleaningUp: .cleaningUp
        case .written: .written
        case .failed: .failed(.noMicrophone)
        }
    }
}

/// Which appearance the drop's glass takes: the app's, or the page's under it where the field's text colour tells it.
private enum LabGlass: String { case app, page }

private struct DictationDropLabBoard: View {
    let appearance: (Bool) -> Void
    /// One visualizer at the drop's real surroundings, or nil for all of them in rows, to compare and to capture at once.
    @State private var kind = DebugFlags.dictationDropLab("Visualizer").flatMap(DictationVisualizer.init(rawValue:))
    @State private var phase = DebugFlags.dictationDropLab("Phase").flatMap(LabPhase.init(rawValue:)) ?? .auto
    @State private var dark = DebugFlags.dictationDropLab("Appearance") == "dark"
    @State private var glass = DebugFlags.dictationDropLab("Glass").flatMap(LabGlass.init(rawValue:)) ?? .app
    @State private var reduceMotion = DebugFlags.dictationDropLab("ReduceMotion").map { NSString(string: $0).boolValue } ?? false
    @State private var silence = DebugFlags.dictationDropLab("Silence").map { NSString(string: $0).boolValue } ?? false
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                GlassChoice(title: "Visualizer", choices: [(DictationVisualizer?.none, "All")] + DictationVisualizer.allCases.map { (Optional($0), $0.rawValue.capitalized) },
                            selection: $kind)
                GlassChoice(title: "Phase", choices: LabPhase.allCases.map { ($0, $0.title) }, selection: $phase)
            }
            HStack(spacing: 16) {
                GlassChoice(title: "Appearance", choices: [(false, "Light"), (true, "Dark")], selection: $dark)
                GlassChoice(title: "Glass", choices: [(LabGlass.app, "App"), (.page, "Page")], selection: $glass)
                Spacer()
                Toggle("Reduce Motion", isOn: $reduceMotion)
                Toggle("Silence", isOn: $silence)
            }
            .toggleStyle(.switch)
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSince(start)
                let level = silence ? 0 : SyntheticLoudness.level(at: time), state = phase.state(at: time)
                VStack(alignment: .leading, spacing: kind == nil ? 4 : 10) {
                    ForEach(kind.map { [$0] } ?? DictationVisualizer.allCases, id: \.self) { voice in
                        HStack(spacing: 12) {
                            if kind == nil { Text(voice.rawValue.capitalized).font(.callout.weight(.medium)).frame(width: 64, alignment: .leading) }
                            ForEach(LabBackdrop.allCases, id: \.self) { backdrop in
                                let dark = glass == .page ? backdrop.pageDark ?? dark : dark
                                backdrop.frame(width: 300, height: kind == nil ? 80 : 160, compact: kind == nil).overlay(alignment: .bottomTrailing) {
                                    DictationCapsule(state: state, action: nil) {
                                        DictationVisualizerView(kind: voice, phase: state, loudness: level, isDark: dark,
                                                                reduceMotion: reduceMotion || systemReduceMotion)
                                    }
                                    .glassEffect(.regular, in: .capsule)
                                    .animation(.spring(duration: 0.4, bounce: 0.12), value: state)
                                    .environment(\.colorScheme, dark ? .dark : .light)
                                    .padding(kind == nil ? 8 : 16)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    Text(String(format: "%4.1f s  ·  level %.2f", time.truncatingRemainder(dividingBy: SyntheticLoudness.period), level))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: dark) { _, dark in appearance(dark) }
        // Restart the curve with each visualizer, so recordings of each line up.
        .onChange(of: kind) { start = Date() }
        .onAppear { appearance(dark) }
    }
}

/// Where a drop lands: an email draft in a light window, a chat in a dark one, a form on a mid-grey page, a message
/// over a loud wallpaper.
enum LabBackdrop: CaseIterable {
    case lightText, darkText, grey, busy

    /// Whether the page is dark, as the colour of its text tells it: what a drop could learn from the field it serves.
    /// A wallpaper tells nothing.
    var pageDark: Bool? {
        switch self {
        case .lightText, .grey: false
        case .darkText: true
        case .busy: nil
        }
    }

    /// The backdrop without its text.
    @ViewBuilder var plain: some View {
        switch self {
        case .lightText: Color.white
        case .darkText: Color(red: 0.12, green: 0.12, blue: 0.13)
        case .grey: Color(white: 0.6)
        case .busy:
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.4], [1, 0.5], [0, 1], [0.5, 1], [1, 1],
            ], colors: [.orange, .pink, .purple, .yellow, .red, .blue, .green, .teal, .indigo])
        }
    }

    var body: some View { body(compact: false) }

    /// Compact keeps one line of the text, clear of a drop in a short row.
    private func body(compact: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            plain
            Text(text).font(.system(size: 13)).lineSpacing(3).lineLimit(compact ? 1 : nil).padding(compact ? 8 : 14)
                .foregroundStyle(pageDark == false ? Color(white: 0.15) : .white.opacity(0.9))
        }
    }

    func frame(width: CGFloat, height: CGFloat, compact: Bool = false) -> some View {
        body(compact: compact).frame(width: width, height: height)
    }

    private var text: String {
        switch self {
        case .lightText: "Hi Sam, thanks for sending the deck over. I went through the numbers this morning and I think we should move the review to Friday so"
        case .darkText: "sure, I can take the first half of the call. do you want me to walk them through the timeline or just the budget part"
        case .grey: "Delivery notes: leave the parcel with the concierge on the ground floor, and ring twice if"
        case .busy: "Running ten minutes late, save me a seat! The train is stuck just outside the station again and"
        }
    }
}
#endif
