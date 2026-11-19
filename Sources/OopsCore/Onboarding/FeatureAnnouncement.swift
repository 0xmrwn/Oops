/// What to tell someone who set Oops up before a feature existed.
public enum FeatureAnnouncement {
    /// The feature to announce, once: one this build offers, that is off, and that was never announced. Fix is
    /// what Oops always did, so it is never news; first run announces every feature it offers.
    public static func pending(offered: [OnboardingFeature], on: Set<OnboardingFeature>, announced: Set<OnboardingFeature>) -> OnboardingFeature? {
        offered.first { $0 != .fix && !on.contains($0) && !announced.contains($0) }
    }
}
