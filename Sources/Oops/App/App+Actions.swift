import OopsCore

extension AppDelegate {
    /// Settings' Try runs on the Actions session, which is built on first use: Try asks for it when Run is pressed.
    func wireActionsTry() {
        ActionTryModel.shared.perform = { [weak self] invocation in
            guard let self else { return nil }
            await self.settings.focusTry(ActionTryModel.shared.editor)
            guard let outcome = await self.actions.run(invocation, inTry: true)?.value else { return nil }
            return ActionTryRun(outcome: outcome, committed: self.actions.committed)
        }
    }

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
        actions.retryInTry = { ActionTryModel.shared.retry($0) }
        actions.tryDraftFocused = { ActionTryModel.shared.draftIsFocused }
        return actions
    }
}
