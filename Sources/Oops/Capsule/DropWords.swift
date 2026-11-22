/// What the drop's controls are called for the feature showing in it.
struct DropWords: Equatable {
    var started: String, cancel: String, revert: String, copy: String
    /// The shortcut that cancels too, named in the cancel tooltip; nil where pressing it again does nothing.
    var cancelShortcut: ShortcutSettings.Action?
    static let fix = DropWords(started: "Correction started", cancel: "Cancel correction", revert: "Revert correction",
                               copy: "Copy correction", cancelShortcut: .correct)
    static let actions = DropWords(started: "Action started", cancel: "Cancel action", revert: "Restore original",
                                   copy: "Copy result", cancelShortcut: nil)
}
