#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// The dictation drop with each voice visualizer, over a light text area, a dark one and a busy one, driven by
/// `SyntheticLoudness` rather than a microphone, so each can be watched and recorded. The drop here is a
/// stand-in at the real drop's size, glass and type, with the visualizer where the real drop has its symbol.
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
        window.center()
        self.window = window
        NSApp.enterDock()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

private enum LabPhase: String, CaseIterable {
    /// Listening through the curve's speech, then transcribing through its closing silence.
    case auto, listening, transcribing, failed

    func state(at time: Double) -> DictationDropState {
        switch self {
        case .auto: time.truncatingRemainder(dividingBy: SyntheticLoudness.period) < 10.2 ? .recording : .transcribing
        case .listening: .recording
        case .transcribing: .transcribing
        case .failed: .failed(.noMicrophone)
        }
    }
}

private struct DictationDropLabBoard: View {
    let appearance: (Bool) -> Void
    @State private var kind = DebugFlags.dictationDropLab("Visualizer").flatMap(DictationVisualizer.init(rawValue:)) ?? .wave
    @State private var phase = DebugFlags.dictationDropLab("Phase").flatMap(LabPhase.init(rawValue:)) ?? .auto
    @State private var dark = DebugFlags.dictationDropLab("Appearance") == "dark"
    @State private var reduceMotion = DebugFlags.dictationDropLab("ReduceMotion").map { NSString(string: $0).boolValue } ?? false
    @State private var silence = DebugFlags.dictationDropLab("Silence").map { NSString(string: $0).boolValue } ?? false
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                GlassChoice(title: "Visualizer", choices: DictationVisualizer.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $kind)
                GlassChoice(title: "Phase", choices: LabPhase.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $phase)
                GlassChoice(title: "Appearance", choices: [(false, "Light"), (true, "Dark")], selection: $dark)
                Spacer()
                Toggle("Reduce Motion", isOn: $reduceMotion)
                Toggle("Silence", isOn: $silence)
            }
            .toggleStyle(.switch)
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSince(start)
                let level = silence ? 0 : SyntheticLoudness.level(at: time), state = phase.state(at: time)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        ForEach(LabBackdrop.allCases, id: \.self) { backdrop in
                            backdrop.frame(width: 300, height: 160).overlay(alignment: .bottomTrailing) {
                                LabDrop(kind: kind, state: state, dark: dark) {
                                    DictationVisualizerView(kind: kind, phase: state, loudness: level, isDark: dark,
                                                            reduceMotion: reduceMotion || systemReduceMotion)
                                }
                                .padding(16)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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

/// A stand-in for `DictationDropView` at its size, glass, type and halo, with a voice where its symbol is: a
/// strip after the drop's padding, or the ripple centred in the leading cap as Fix centres its eyes.
struct LabDrop<Voice: View>: View {
    let kind: DictationVisualizer
    let state: DictationDropState
    let dark: Bool
    @ViewBuilder let voice: () -> Voice
    private static var height: CGFloat { EyesDropView.drop }

    private static func lead(_ kind: DictationVisualizer, state: DictationDropState) -> CGFloat {
        let size = DictationVisualizerView.size(kind, phase: state)
        return kind == .ripple && state.isLive ? (height - size.width) / 2 : 16 - (state.isLive ? 4 : 0)
    }

    /// The drop's width, as `DictationDropView` computes its own rather than measuring.
    static func width(_ kind: DictationVisualizer, state: DictationDropState) -> CGFloat {
        let text = (state.text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)]).width
        return lead(kind, state: state) + DictationVisualizerView.size(kind, phase: state).width + 7 + text.rounded(.up) + 16
    }

    var body: some View {
        let ink = VoiceInk(isDark: dark)
        let lead = Self.lead(kind, state: state)
        HStack(spacing: 7) {
            voice()
            Text(state.text).font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize()
                .foregroundStyle(ink.ink).modifier(Halo(color: ink.halo))
        }
        .padding(.leading, lead).padding(.trailing, 16)
        .frame(height: Self.height)
        .background { GlassEffectContainer { Color.clear.glassEffect(.clear, in: .capsule) } }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// Where a drop lands: an email draft in a light window, a chat in a dark one, a message over a loud wallpaper.
enum LabBackdrop: CaseIterable {
    case lightText, darkText, busy

    /// The backdrop without its text.
    @ViewBuilder var plain: some View {
        switch self {
        case .lightText: Color.white
        case .darkText: Color(red: 0.12, green: 0.12, blue: 0.13)
        case .busy:
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.4], [1, 0.5], [0, 1], [0.5, 1], [1, 1],
            ], colors: [.orange, .pink, .purple, .yellow, .red, .blue, .green, .teal, .indigo])
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            plain
            Text(text).font(.system(size: 13)).lineSpacing(3).padding(14)
                .foregroundStyle(self == .lightText ? Color(white: 0.15) : .white.opacity(0.9))
        }
    }

    func frame(width: CGFloat, height: CGFloat) -> some View { body.frame(width: width, height: height) }

    private var text: String {
        switch self {
        case .lightText: "Hi Sam, thanks for sending the deck over. I went through the numbers this morning and I think we should move the review to Friday so"
        case .darkText: "sure, I can take the first half of the call. do you want me to walk them through the timeline or just the budget part"
        case .busy: "Running ten minutes late, save me a seat! The train is stuck just outside the station again and"
        }
    }
}
#endif
