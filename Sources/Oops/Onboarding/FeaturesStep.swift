import OopsCore
import SwiftUI

/// First run's opening question: what Oops is for. Each feature is a switch, and the steps after it are
/// the ones the chosen features need.
@MainActor @Observable final class FeaturesStep {
    /// An unfinished first run's choice, so the relaunch Accessibility can need reopens on the same steps.
    static let key = "onboardingFeatures"
    private(set) var chosen: Set<OnboardingFeature>
    private let saves: Bool

    init(saves: Bool) {
        self.saves = saves
        let saved = UserDefaults.standard.stringArray(forKey: Self.key)
        if saves, OnboardingWindow.finished {
            // Show welcome: what is on now. A run that saves nothing plays a first run.
            chosen = Set(OnboardingFeature.allCases.filter { ShortcutSettings.shared.shortcut($0.action) != nil })
        } else if saves, let saved {
            chosen = Set(saved.compactMap(OnboardingFeature.init(rawValue:)))
        } else {
            chosen = Set(OnboardingFeature.allCases)
        }
    }

    /// The companion drop watches the rows.
    var look: CGSize { CGSize(width: 0, height: 0.6) }

    func toggle(_ feature: OnboardingFeature) {
        if chosen.remove(feature) == nil { chosen.insert(feature) }
    }

    /// Continue: the shortcut is the switch, so a feature left out loses its shortcut. Fix gets its default
    /// back when chosen; Dictate's is recorded at the Shortcut step.
    func commit() {
        guard saves else { return }
        UserDefaults.standard.set(chosen.map(\.rawValue).sorted(), forKey: Self.key)
        for feature in OnboardingFeature.allCases where !chosen.contains(feature) { ShortcutSettings.shared.turnOff(feature.action) }
        if chosen.contains(.fix), ShortcutSettings.shared.off.contains(.correct) { try? ShortcutSettings.shared.set(.correct, nil) }
    }

    #if DEBUG
    func seed(_ chosen: Set<OnboardingFeature>) { self.chosen = chosen }
    #endif
}

extension OnboardingFeature {
    /// The shortcut that switches the feature on.
    var action: ShortcutSettings.Action { self == .fix ? .correct : .dictate }
    /// The feature's name, as its Settings tab has it.
    var title: String { action.tab.rawValue }
}
