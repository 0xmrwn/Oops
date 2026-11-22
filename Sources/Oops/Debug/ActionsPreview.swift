#if DEBUG
import OopsCore

/// Launch-only Actions pages for captures (`-SettingsPreviewAction`).
@MainActor enum ActionsPreview {
    static func launch(_ navigation: ActionsNavigation) {
        let library = navigation.library
        switch DebugFlags.settingsAction?.lowercased() {
        case nil: return
        case "typed": navigation.openRunsWith(.typed)
        case "new": if let place = ActionPlace.allCases.first(where: library.library.canAdd(at:)) { navigation.add(at: place) }
        case let name?:
            if let action = library.library.actions.first(where: { $0.name.lowercased().hasPrefix(name) }) { navigation.edit(action.id) }
        }
    }
}
#endif
