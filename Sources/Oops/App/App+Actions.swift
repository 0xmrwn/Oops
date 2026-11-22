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

    /// Actions shares Fix's editor (one Chromium switch registry) and the drop; an agent run shows in it too, and in
    /// the menu bar.
    func makeActions() -> ActionSession {
        let editor = session.editor, providers = preferences.providers
        let actions = ActionSession(editor: editor, providers: providers,
                                    drop: ActionDropOwner(owner: drop) { await editor.geometry(of: $0) },
                                    agentDrop: AgentDrop(owner: drop) { await editor.geometry(of: $0) },
                                    agentRunner: { try providers.agentRunner() })
        actions.agent.changed = { [weak self] in self?.menuBar?.agentChanged() }
        actions.agent.escape = { [weak self] in self?.armEscape(.agent, $0 ? [0] : []) }
        menuBar?.agent = { [weak actions] in actions?.agent }
        actions.agent.refused = { [weak self] in self?.preferences.status = $0 }
        actions.agent.othersBusy = { [weak self, weak actions] in self?.session.isBusy == true || actions?.isBusy == true }
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

    /// The Actions shortcut takes a ready agent result back to its draft before anything else; otherwise it opens the wheel.
    func actionsShortcut() {
        if actions.agent.isReady { actions.agent.act() } else { wheel.shortcut() }
    }

    /// Registers the union of every feature's Escape chords (Carbon modifiers; 0 is plain Escape).
    func armEscape(_ feature: DropFeature, _ chords: [UInt32]) {
        shortcuts.armCancel(escapes.arm(feature, chords))
    }

    /// Escape goes to Dictate whenever it armed it, else to the agent run whose drop is in front.
    func escapePressed() {
        if escapes.target == .agent { actions.agent.cancel() } else { dictation?.cancel() }
    }
}
