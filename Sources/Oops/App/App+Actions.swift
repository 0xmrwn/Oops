import OopsCore

extension AppDelegate {
    /// Actions shares Fix's editor (one Chromium switch registry) and the drop.
    func makeActions() -> ActionSession {
        let editor = session.editor
        let actions = ActionSession(editor: editor, providers: preferences.providers,
                                    drop: ActionDropOwner(owner: drop) { await editor.geometry(of: $0) })
        actions.forgetFix = { [weak self] in
            self?.session.remember(nil); self?.session.testEditor.restoreUnavailable()
        }
        actions.openSettings = { [weak self] providers in
            if providers { self?.preferences.providers.wantsProvidersPage = true }
            self?.settings.show()
        }
        return actions
    }
}
