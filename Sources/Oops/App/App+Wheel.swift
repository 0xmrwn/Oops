import OopsCore

extension AppDelegate {
    /// The wheel opens on the Actions shortcut and runs what is chosen through the Actions session.
    func makeWheel() -> WheelController {
        let actions = actions
        let wheel = WheelController(actions: actions, drop: drop, editor: session.editor, library: { actions.library.library }) {
            let settings = ShortcutSettings.shared
            return ShortcutSettings.Action.allCases.compactMap { action in
                if case let .chord(shortcut) = settings.registration(action) { shortcut } else { nil }
            }
        }
        wheel.refused = { [weak self] message in self?.preferences.status = message }
        return wheel
    }
}
