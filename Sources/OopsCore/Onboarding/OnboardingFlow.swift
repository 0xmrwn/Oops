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

    /// Try it's beats, in order: Fix's, then the spoken one. A feature with no shortcut is off, so Dictate's beat
    /// needs its shortcut saved: skipped at the Shortcut step, there are no keys to hold.
    public static func tries(for features: Set<OnboardingFeature>, dictateShortcut: Bool) -> [OnboardingFeature] {
        OnboardingFeature.allCases.filter { features.contains($0) && ($0 != .dictate || dictateShortcut) }
    }

    /// The step after this one in `steps`. A Try it with nothing to try is passed over.
    public func next(in steps: [OnboardingStep], tries: [OnboardingFeature]) -> OnboardingStep? {
        guard let index = steps.firstIndex(of: self) else { return nil }
        return steps.dropFirst(index + 1).first { $0 != .tryIt || !tries.isEmpty }
    }
}
