import SwiftUI

/// A sketch of System Settings' Accessibility list (`AccessibilityStep.paneName`) in onboarding's
/// own glass and white ink, not a copy of it: the pane's icon, name and description, two other apps'
/// rows and Oops's, dashed with its switch off until the permission is on. A ghost drop falls into
/// that row every few seconds, the motion to make.
struct AccessibilityListSketch: View {
    let granted: Bool
    let demo: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingEffectsVisible) private var visible

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PaneIcon()
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: AccessibilityStep.paneName).font(.system(size: 13, weight: .semibold)).opacity(0.75)
                    Capsule().fill(.white.opacity(0.16)).frame(width: 220, height: 5)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            row(bar: 96, on: true)
            separator
            row(bar: 68, on: false)
            separator
            oops.padding(.top, 2)
        }
        .padding(.bottom, 10)
        .frame(width: 440)
        .background { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 24)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(granted ? "Oops is on in \(AccessibilityStep.paneName)" : "Oops is not in \(AccessibilityStep.paneName) yet")
    }

    private var separator: some View { Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.leading, 60).padding(.trailing, 20) }

    /// Another app: a blank tile, a bar for its name and its switch, quieter than Oops's row.
    private func row(bar: CGFloat, on: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.2)).frame(width: 28, height: 28)
            Capsule().fill(.white.opacity(0.26)).frame(width: bar, height: 7)
            Spacer()
            SketchSwitch(on: on).opacity(0.55)
        }
        .padding(.horizontal, 20).frame(height: 46)
    }

    private var oops: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.clear.glassEffect(.clear, in: .circle)
                DashEyes(look: granted ? .zero : CGSize(width: 0, height: -0.6), lid: 0, ink: .white, halo: .black.opacity(0.3)).padding(5)
            }
            .frame(width: 28, height: 28)
            .opacity(granted ? 1 : 0.5)
            .overlay(alignment: .bottom) { if demo, visible, !reduceMotion { GhostDrop() } }
            Text(verbatim: "Oops").font(.system(size: 15, weight: .semibold)).opacity(granted ? 1 : 0.5)
            Spacer()
            SketchSwitch(on: granted)
        }
        .padding(.horizontal, 12).frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(granted ? 0 : 0.55), style: StrokeStyle(lineWidth: 1.25, dash: [6, 5]))
        }
        .padding(.horizontal, 8)
        .animation(.spring(duration: 0.5, bounce: 0.25), value: granted)
    }
}

/// The pane's own icon, the one colour in the sketch so it's recognisable at a glance: System
/// Settings' white symbol on a blue tile, its blue sampled from the icon macOS draws.
private struct PaneIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.6, blue: 1), Color(red: 0, green: 0.51, blue: 0.97)], startPoint: .top, endPoint: .bottom))
            .frame(width: 34, height: 34)
            .overlay { Image(systemName: AccessibilityStep.paneSymbol).font(.system(size: 17, weight: .medium)).foregroundStyle(.white) }
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// A switch in the sketch, in white ink: filled with a dark knob when on, a faint track when off.
private struct SketchSwitch: View {
    let on: Bool
    var body: some View {
        Capsule().fill(.white.opacity(on ? 0.9 : 0.18))
            .frame(width: 34, height: 20)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(on ? Color(white: 0.16) : .white.opacity(0.9)).frame(width: 16, height: 16).padding(2)
            }
            .animation(.spring(duration: 0.4, bounce: 0.3), value: on)
    }
}

/// The motion to make: a small drop falls from above into Oops's row, settles, fades, and again.
private struct GhostDrop: View {
    private struct Frame { var y: CGFloat = -130; var opacity = 0.0; var scale = 1.3 }

    var body: some View {
        ZStack {
            Color.clear.glassEffect(.clear, in: .circle)
            DashEyes(look: CGSize(width: 0, height: 0.8), lid: 0, ink: .white, halo: .black.opacity(0.3)).padding(5)
        }
        .frame(width: 28, height: 28)
        .keyframeAnimator(initialValue: Frame(), repeating: true) { content, frame in
            content.offset(y: frame.y).opacity(frame.opacity).scaleEffect(frame.scale)
        } keyframes: { _ in
            KeyframeTrack(\.y) {
                LinearKeyframe(-130, duration: 0.6)
                SpringKeyframe(0, duration: 0.9, spring: .bouncy(duration: 0.6, extraBounce: 0.05))
                LinearKeyframe(0, duration: 1.9)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: 0.6)
                LinearKeyframe(0.95, duration: 0.3)
                LinearKeyframe(0.95, duration: 0.8)
                LinearKeyframe(0, duration: 0.4)
                LinearKeyframe(0, duration: 1.3)
            }
            KeyframeTrack(\.scale) {
                LinearKeyframe(1.3, duration: 0.6)
                SpringKeyframe(1, duration: 0.9)
                LinearKeyframe(1, duration: 1.9)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
