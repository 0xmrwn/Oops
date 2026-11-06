import SwiftUI

extension View {
    /// Keep the same repeating animation, but stop it when motion is reduced or the view leaves.
    func repeatingMotion(_ phase: Binding<Bool>, animation: Animation, enabled: Bool = true) -> some View {
        modifier(RepeatingMotion(phase: phase, animation: animation, enabled: enabled))
    }
}

private struct RepeatingMotion: ViewModifier {
    @Binding var phase: Bool
    let animation: Animation
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingEffectsVisible) private var visible

    func body(content: Content) -> some View {
        content
            .onChange(of: visible && enabled && !reduceMotion, initial: true) { _, running in
                withAnimation(running ? animation : nil) { phase = running }
            }
            .onDisappear { withAnimation(nil) { phase = false } }
    }
}
