import SwiftUI

/// The Shortcut step over Hello's wallpaper, under the same companion drop as Provider: the eyes watch
/// the keycaps and turn into a check once the shortcut is pressed. With both features chosen it records
/// Fix's shortcut, which then steps aside for Dictate's; accepting Dictate's is when the microphone is asked for.
struct ShortcutStepView: View {
    let fix: ShortcutStep?
    let dictate: ShortcutStep?
    let microphone: MicrophoneStep
    let next: () -> Void
    /// Fix's shortcut is in and Dictate's keys have taken its place.
    @State private var onDictate = false

    /// The recorder whose keys show: Fix's, then Dictate's.
    private var step: ShortcutStep? { onDictate || fix == nil ? dictate : fix }
    private var refused: Bool { step === dictate && microphone.state == .refused }
    private var ready: Bool {
        fix?.phase ?? .accepted == .accepted && dictate?.phase ?? .accepted == .accepted && (dictate == nil || microphone.state == .granted)
    }

    var body: some View {
        OnboardingStepLayout(height: 400) { column } primary: {
            if refused {
                OnboardingNextButton(title: "Open System Settings", icon: "gearshape", symbol: nil, width: 240, action: MicrophoneStep.openSettings)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if ready {
                OnboardingNextButton(title: "Continue", action: next).transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        } skip: {
            if !ready { OnboardingSkipButton(action: next).transition(.opacity) }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: ready)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: refused)
        .onAppear { onDictate = fix == nil || (fix?.phase == .accepted && dictate != nil && dictate?.phase != .accepted); step?.start() }
        .onDisappear { for keys in [fix, dictate] where keys?.isMirroring == false { keys?.stop() } }
        .onChange(of: fix?.phase) { _, phase in
            guard phase == .accepted, let dictate, !onDictate else { return }
            // A beat on Fix's check before Dictate's keys take the stage.
            Task {
                try? await Task.sleep(for: .seconds(0.9))
                guard fix?.phase == .accepted else { return }
                fix?.stop()
                withAnimation(.spring(duration: 0.55, bounce: 0.25)) { onDictate = true }
                dictate.start()
            }
        }
        .onChange(of: dictate?.phase) { _, phase in
            guard phase == .accepted else { return }
            microphone.ask()
            // Dictate just came on: its model warms now, as it would have at launch.
            if dictate?.saves == true { (NSApp.delegate as? AppDelegate)?.warmUpDictation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in microphone.recheck() }
    }

    private var title: String {
        if refused { return "Microphone access is off" }
        // Dictate's shortcut is always named: alone on the step, nothing else says what the keys are for.
        if step?.phase == .recording { return step === dictate ? "Press the new Dictate shortcut" : "Press the new shortcut" }
        if step === dictate { return "Press your Dictate shortcut" }
        return dictate == nil ? "Press your shortcut" : "Press your Fix shortcut"
    }

    @ViewBuilder private var keys: some View {
        if let step {
            let recording = step.phase == .recording
            let keycaps = Keycaps(caps: step.caps, recording: recording)
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(recording ? "Recording" : step.spoken)
            // Beneath the keycaps, a smaller key of the same glass: the keys' own control, not one of them.
            VStack(spacing: 4) {
                keycaps
                ShortcutChangeKey(recording: recording, height: 44, radius: 12, font: 15) {
                    if recording { step.cancelRecording() } else { step.change() }
                }
            }
            .id(step.action)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    /// Fix's shortcut once it is in, small above Dictate's keys.
    @ViewBuilder private var done: some View {
        if onDictate, let fix, let label = fix.shortcut?.label {
            HStack(spacing: 8) {
                Text("Fix").fontWeight(.semibold)
                Text(label).monospaced()
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 30)
            .glassEffect(.clear, in: .capsule)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fix shortcut \(fix.spoken), set")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 84, height: 84)
                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["step": $0] }
            Text(title).font(.system(size: 26, weight: .semibold)).padding(.top, 20)
                .contentTransition(.opacity)
            done.frame(height: 30).padding(.top, 10)
            keys.padding(.top, 4)
            Group {
                if let error = step?.error {
                    HStack(spacing: 12) {
                        Text(error).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                            .frame(maxWidth: 440).opacity(0.85)
                        // The keys may be the person's own keyboard tool's, which looks the same from here.
                        if let step, let chord = step.offered {
                            Button("Use anyway", action: step.useAnyway).buttonStyle(.settingsGlass).controlSize(.small)
                                .help("Save \(chord.label) anyway")
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 34)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: step?.phase)
        .animation(.easeOut(duration: 0.25), value: title)
    }
}

/// The shortcut as large glass keys that float, sink while held and light up as their keys go down.
/// Recording with nothing held shows one empty key, waiting.
private struct Keycaps: View {
    let caps: [ShortcutStep.Cap]
    let recording: Bool

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                if caps.isEmpty {
                    EmptyKeycap()
                } else {
                    ForEach(caps) { cap in
                        Keycap(cap: cap).transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: caps.map(\.label))
    }
}

private struct Keycap: View {
    let cap: ShortcutStep.Cap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false

    var body: some View {
        let wide = cap.label.count > 1
        // The legend sits on the glass, as the drop's eyes do, with a halo rather than a plate. Legend
        // and hairline are the glass's own content: drawn after `glassEffect` inside the container, they
        // fall behind the glass, whose rim then lenses them into ripples along the key's edges.
        Group {
            if cap.parts.isEmpty {
                Text(cap.label).font(.system(size: wide ? 30 : 44, weight: .medium, design: .rounded))
            } else {
                HyperLegend(cap: cap, size: 28, partSize: 17)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 3)
        .frame(width: wide ? 168 : 112, height: 112)
        .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.2 + 0.55 * cap.lit), lineWidth: 1.5) }
        .glassEffect(.clear.tint(.white.opacity(0.32 * cap.lit)), in: .rect(cornerRadius: 26))
        .shadow(color: .white.opacity(0.35 * cap.lit), radius: 22)
        .scaleEffect(cap.down ? 0.94 : 1)
        .offset(y: cap.down ? 5 : reduceMotion ? 0 : floating ? -5 : 5)
        .animation(.spring(duration: 0.18, bounce: 0.35), value: cap.down)
        .repeatingMotion($floating, animation: .easeInOut(duration: 2.6).repeatForever().delay(Double(cap.id) * 0.35))
    }
}

private struct EmptyKeycap: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 26)
            .strokeBorder(.white.opacity(reduceMotion || pulse ? 0.7 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            .frame(width: 112, height: 112)
            // Reduced mode keeps the bright endpoint: replace the decorative shape to end its pulse.
            .id(reduceMotion)
            .repeatingMotion($pulse, animation: .easeInOut(duration: 0.9).repeatForever())
    }
}

/// Hyper's legend: its mark and name over the four modifiers it stands for, each lit as it is held.
struct HyperLegend: View {
    let cap: ShortcutStep.Cap
    let size: CGFloat
    let partSize: CGFloat

    var body: some View {
        VStack(spacing: partSize * 0.3) {
            Text(verbatim: Shortcut.hyperKey).font(.system(size: size, weight: .medium, design: .rounded))
            HStack(spacing: partSize * 0.45) {
                ForEach(cap.parts) { part in
                    Text(part.label).font(.system(size: partSize, weight: .semibold, design: .rounded))
                        .opacity(0.3 + 0.7 * part.lit)
                        .shadow(color: .white.opacity(0.9 * part.lit), radius: partSize * 0.35)
                        .scaleEffect(1 + 0.1 * part.lit)
                        .offset(y: part.down ? partSize * 0.08 : 0)
                }
            }
        }
    }
}
