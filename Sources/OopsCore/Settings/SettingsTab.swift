import Foundation

/// Settings' tabs, in tab-bar order. Dictate and Actions show only while their feature is switched on.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General", fix = "Fix", dictate = "Dictate", actions = "Actions", providers = "Providers"
    public var id: Self { self }

    /// The tabs the bar shows; ⌘1…n select them in this order.
    public static func visible(dictation: Bool, actions: Bool) -> [Self] {
        allCases.filter { tab in
            switch tab {
            case .dictate: dictation
            case .actions: actions
            default: true
            }
        }
    }

    /// The tab a `-SettingsPreviewTab` name opens on: a tab's own name, or a page inside one. A hidden
    /// tab, or a name nothing knows, opens General.
    public static func launch(_ name: String?, visible: [Self]) -> Self {
        let tab: Self = switch name?.lowercased() {
        case "fix", "try", "customize", "advanced", "apps": .fix
        case "dictate", "dictation": .dictate
        case "actions": .actions
        case "provider", "providers": .providers
        default: .general
        }
        return visible.contains(tab) ? tab : .general
    }

    /// Where `tab` slides from, relative to the one shown: -1 from the left, 0 shown, 1 from the right.
    public static func side(of tab: Self, shown: Self, in visible: [Self]) -> Int {
        ((visible.firstIndex(of: tab) ?? 0) - (visible.firstIndex(of: shown) ?? 0)).signum()
    }
}
