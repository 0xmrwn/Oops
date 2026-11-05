import AppKit

/// Shared editing commands, including the isolated onboarding review where no app delegate runs.
@MainActor enum AppMenus {
    static func edit() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return edit
    }

    #if DEBUG
    static func installReview() {
        let main = NSMenu(), app = NSMenu(title: "Oops")
        app.addItem(withTitle: "Quit Oops", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Oops", action: nil, keyEquivalent: "").submenu = app
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit()
        NSApp.mainMenu = main
    }
    #endif
}
