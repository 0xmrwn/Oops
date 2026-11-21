/// A feature first run can turn on. The list grows: Actions joins it when it ships.
public enum OnboardingFeature: String, CaseIterable, Sendable {
    case fix, dictate
}

/// First run's steps. An unfinished first run saves the raw value to reopen at.
public enum OnboardingStep: String, Sendable {
    case hello, features, provider, shortcut, accessibility, tryIt, home

    /// The steps after Hello, which the dots count: first run opens by asking what Oops is for and keeps the
    /// steps `features` need.
    public static func setup(for features: Set<OnboardingFeature>) -> [OnboardingStep] {
        // Only Fix needs a text provider: dictation's model is Oops's own download.
        [.features] + (features.contains(.fix) ? [.provider] : []) + [.shortcut, .accessibility, .tryIt, .home]
    }
}
