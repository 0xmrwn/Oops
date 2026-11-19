import OopsCore
import SwiftUI

/// The choice step over Hello's wallpaper: a glass row per feature with the switch that turns it on. A
/// row shows its feature at work rather than describing it.
struct FeaturesStepView: View {
    let step: FeaturesStep
    let next: () -> Void
    @State private var previews = FeaturePreviews()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingEffectsVisible) private var visible

    var body: some View {
        let moving = visible && !reduceMotion
        OnboardingStepLayout(height: 400) { column } primary: {
            if !step.chosen.isEmpty {
                OnboardingNextButton(title: "Continue", action: next).transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: step.chosen.isEmpty)
        // Still, the rows rest on what each feature leaves behind.
        .task(id: moving) { if moving { await previews.play() } }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 84, height: 84)
                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["step": $0] }
            Text("What should Oops do?").font(.system(size: 26, weight: .semibold)).padding(.top, 20)
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 14) { ForEach(OnboardingFeature.allCases, id: \.self, content: row) }
            }
            .padding(.top, 34)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ feature: OnboardingFeature) -> some View {
        let isOn = step.chosen.contains(feature)
        return Toggle(isOn: Binding(get: { isOn }, set: { _ in step.toggle(feature) })) {
            HStack(spacing: 16) {
                // Settings' own symbols, so a tab there is recognised from here.
                Label(feature.title, systemImage: (feature == .fix ? SettingsTab.fix : .dictate).symbol)
                    .font(.system(size: 20, weight: .semibold)).labelStyle(FeatureLabel())
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .frame(width: 128, alignment: .leading)
                Group {
                    switch feature {
                    case .fix: FixPreview(previews: previews)
                    case .dictate: DictatePreview(previews: previews)
                    }
                }
                .opacity(isOn ? 1 : 0.4)
                .accessibilityHidden(true)
            }
        }
        // White ink like Home's switch: the accent colour would be the only colour Oops adds to the step.
        .toggleStyle(.switch).controlSize(.large).tint(.white.opacity(0.85))
        .padding(.horizontal, 24)
        .frame(width: 640, height: 84)
        .contentShape(.rect(cornerRadius: 24))
        .onTapGesture { step.toggle(feature) }
        .glassEffect(.clear.tint(.white.opacity(isOn ? 0.12 : 0)), in: .rect(cornerRadius: 24))
        .animation(.spring(duration: 0.3), value: isOn)
    }
}

/// A row's symbol and name: the symbol in a column of its own, so the two names line up.
private struct FeatureLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.font(.system(size: 18, weight: .semibold)).frame(width: 26)
            configuration.title
        }
    }
}
