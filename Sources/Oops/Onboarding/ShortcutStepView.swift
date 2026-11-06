import SwiftUI

/// The Shortcut step over Hello's wallpaper, under the same companion drop as Provider: the eyes watch
/// the keycaps and turn into a check once the shortcut is pressed.
struct ShortcutStepView: View {
    let step: ShortcutStep
    let next: () -> Void

    var body: some View {
        let ready = step.phase == .accepted
        OnboardingStepLayout(height: 380) { column } primary: {
            if ready { OnboardingNextButton(title: "Continue", action: next).transition(.scale(scale: 0.9).combined(with: .opacity)) }
        } skip: {
            if !ready { OnboardingSkipButton(action: next).transition(.opacity) }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: ready)
        .onAppear { step.start() }
        .onDisappear { step.stop() }
    }

    @ViewBuilder private var keys: some View {
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
    }

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 84, height: 84)
                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["step": $0] }
            Text(step.phase == .recording ? "Press the new shortcut" : "Press your shortcut")
                .font(.system(size: 26, weight: .semibold)).padding(.top, 20)
                .contentTransition(.opacity)
            keys.padding(.top, 34)
            Group {
                if let error = step.error {
                    Text(error).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                        .frame(maxWidth: 440).opacity(0.85).transition(.opacity)
                }
            }
            .frame(height: 34)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: step.phase)
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
