import OopsCore

extension CapsuleModel {
    /// What a failed drop offers next to its reason, in its trailing cap.
    enum Remedy: Equatable { case retry, settings, turnOn(TurnedOffApp) }
}

extension CapsulePanel {
    /// The failed drop's Turn on: Oops is on in `app` at once (the menu bar and Settings follow `AppScope`), and the
    /// drop says so and leaves. The refused Fix or action doesn't run: the button says Turn on, and only Try again
    /// runs something again.
    func turnOn(_ app: TurnedOffApp) {
        AppScope.shared.set(app.bundleID, on: true)
        cancelTimedHide()
        // A fixed drop that can revert offers Undo, which would reach back to an earlier fix.
        model.canRevert = false
        show(.fixed, label: "On in " + app.name, spoken: "Oops is on in " + app.name)
        hide(after: 1.1)
    }
}
