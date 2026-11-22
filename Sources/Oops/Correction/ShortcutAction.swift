import OopsCore

/// How each shortcut's action shows in Settings, the menu and General's overview.
extension ShortcutSettings.Action {
    /// The action's icon everywhere it appears (Settings rows, Try's buttons, stats).
    var symbol: String {
        switch self {
        case .correct: "checkmark.bubble"
        case .dictate: SettingsTab.dictate.symbol
        case .dictateAndCleanUp: "wand.and.sparkles"
        case .actions: SettingsTab.actions.symbol
        }
    }

    /// The action's name in Settings.
    var title: String {
        switch self {
        case .correct: "Fix text"
        case .dictate: "Dictate"
        case .dictateAndCleanUp: "Clean up with AI"
        case .actions: "Actions"
        }
    }

    /// The Settings tab the action belongs to.
    var tab: SettingsTab {
        switch self {
        case .correct: .fix
        case .dictate, .dictateAndCleanUp: .dictate
        case .actions: .actions
        }
    }

    /// Whether the shortcut is its feature's switch, which General's Turn on records.
    var isSwitch: Bool { self != .dictateAndCleanUp }
}
