import SwiftUI

/// Where the setup steps are: a dot each along the bottom, the current one a wider pill.
struct OnboardingProgress: View {
    let steps: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<steps, id: \.self) { index in
                Capsule().fill(.white.opacity(index == current ? 0.9 : index < current ? 0.5 : 0.25))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 3)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps)")
    }
}

extension EnvironmentValues {
    @Entry var onboardingEffectsVisible = true
}
