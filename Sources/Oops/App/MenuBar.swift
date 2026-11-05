import ApplicationServices
import AppKit
import OopsCore
import SwiftUI

/// The menu bar eyes and their menu: a status line, Fix text (or Cancel), Restore last correction,
/// the copy fallbacks, Settings and Quit.
@MainActor final class MenuBar: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let preferences: Preferences
    private let session: CorrectionSession
    private let openSettings: () -> Void
    private let quit: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem()
    private let status = StatusLine()
    private var menuOpen = false

    init(preferences: Preferences, session: CorrectionSession, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.preferences = preferences; self.session = session; self.openSettings = openSettings; self.quit = quit
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        // A view of its own: AppKit draws a disabled item's title and image dimmed, whatever their colour.
        let host = NSHostingView(rootView: StatusLineView(model: status))
        host.frame.size = host.fittingSize
        statusLine.view = host
        menu.addItem(statusLine)
        menu.addItem(withTitle: "Fix text", action: #selector(fix), keyEquivalent: "").image = Self.symbol(ShortcutSettings.Action.correct.symbol)
        menu.addItem(withTitle: "Restore last correction", action: #selector(restore), keyEquivalent: "").image =
            Self.symbol(ShortcutSettings.Action.restore.symbol)
        menu.addItem(withTitle: "Copy pending correction", action: #selector(copyPending), keyEquivalent: "").image = Self.symbol("doc.on.doc")
        menu.addItem(withTitle: "Copy original draft", action: #selector(copyOriginal), keyEquivalent: "").image = Self.symbol("doc.on.doc")
        menu.addItem(withTitle: "Turn off", action: #selector(toggleApp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").image = Self.symbol("gearshape")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Oops", action: #selector(quitApp), keyEquivalent: "q").image = Self.symbol("power")
        for item in menu.items {
            item.target = self
            // macOS 27 hides menu symbols unless an item asks to show its own.
            if #available(macOS 27, *), item.image != nil { item.preferredImageVisibility = .visible }
        }
        if let button = statusItem.button { MenuBarEyes.configure(button) }
        statusItem.menu = menu
    }

    // Lets the menu close before capture reads the focused editor.
    @objc private func fix() { Task { await Task.yield(); session.correct() } }
    @objc private func restore() { Task { await Task.yield(); session.revert() } }
    @objc private func copyPending() { session.copyPending() }
    @objc private func copyOriginal() { session.copyOriginal() }
    @objc private func settings() { openSettings() }
    @objc private func toggleApp() {
        guard let app = targetApp else { return }
        AppScope.shared.set(app, on: !AppScope.shared.isOn(app))
    }

    /// The app in front when the menu opened (a status menu doesn't take it), if Oops could work there.
    private var targetApp: String? {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              !EditorApplicationPolicy.denied.contains(id) else { return nil }
        return id
    }
    @objc private func quitApp() { quit() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyPending): session.pendingCorrection != nil
        case #selector(restore): session.canRestore
        case #selector(copyOriginal): session.originalForRecovery != nil
        default: true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Before layout, so the status line is sized for its text.
        updateStatusLine()
        for item in menu.items {
            switch item.action {
            case #selector(copyPending): item.isHidden = session.pendingCorrection == nil
            case #selector(copyOriginal): item.isHidden = session.originalForRecovery == nil
            case #selector(toggleApp):
                item.isHidden = targetApp == nil
                if let app = targetApp {
                    let on = AppScope.shared.isOn(app)
                    item.title = (on ? "Turn off in " : "Turn on in ") + AppScope.name(app)
                    item.image = Self.symbol(on ? "nosign" : "checkmark.circle")
                    if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
                }
            case #selector(fix):
                item.title = session.isBusy ? "Cancel correction" : "Fix text"
                showChord(.correct, on: item)
            case #selector(restore): showChord(.restore, on: item)
            default: break
            }
        }
    }

    /// The action's chord, if it has one, drawn on the right like Settings and Quit. The global hotkey
    /// owns it; a status menu only matches key equivalents while it is open.
    private func showChord(_ action: ShortcutSettings.Action, on item: NSMenuItem) {
        let chord = ShortcutSettings.shared.shortcut(action)?.keyEquivalent
        item.keyEquivalent = chord?.key ?? ""
        item.keyEquivalentModifierMask = chord?.modifiers ?? []
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        // Health is otherwise refreshed only when Settings opens; each check is at most once a minute.
        preferences.refreshChatGPT()
        preferences.providers.refresh()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    /// Opens the menu as a click on the eyes would (lab captures).
    func open() { statusItem.button?.performClick(nil) }

    /// Where the eyes are on screen, or nil when they can't be seen: removed, or moved off screen by
    /// a menu-bar manager. Onboarding's last step folds into them. (The item's window reports no
    /// occlusion state worth reading: macOS hosts it outside the app.)
    var eyesFrame: CGRect? {
        guard statusItem.isVisible, let window = statusItem.button?.window, window.frame.width > 0,
              NSScreen.screens.contains(where: { $0.frame.contains(window.frame) }) else { return nil }
        return window.frame
    }

    /// The eyes acknowledge what just landed in them: one press-and-release of the button.
    func greet() {
        statusItem.button?.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.statusItem.button?.highlight(false) }
    }

    /// Not clickable: whether a fix would work right now and with which model, then the tally
    /// Settings shows in its header. Follows the providers while the menu is open, so a check
    /// that finishes then turns "Checking" into "Ready" in place.
    private func updateStatusLine() {
        let store = preferences.providers
        withObservationTracking {
            let fixed = Stats.shared.mistakesFixed
            status.subtitle = fixed > 0 ? "\(fixed.formatted()) mistakes fixed" : nil
            let warning = Self.symbol("exclamationmark.triangle")
            if session.isBusy {
                setStatus("Fixing…", image: Self.symbol(ShortcutSettings.Action.correct.symbol))
            } else if !AXIsProcessTrusted() {
                setStatus("Allow Accessibility", image: warning)
            } else if let provider = store.currentProvider, let model = store.currentModel {
                let state = store.problem(provider.id) ?? (store.status(provider.id).busy ? "Checking" : "Ready")
                setStatus(model.name + " · " + state, image: Self.mark(provider))
            } else {
                setStatus(store.pickerGroups.isEmpty ? "Add a provider" : "Choose a model", image: warning)
            }
        } onChange: { [weak self] in
            Task { @MainActor in if self?.menuOpen == true { self?.updateStatusLine() } }
        }
    }

    private func setStatus(_ title: String, image: NSImage?) {
        status.title = title
        status.image = image
        if let host = statusLine.view as? NSHostingView<StatusLineView> {
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
        }
    }

    /// `ProviderMark` as a 16 pt template image for the status line.
    private static func mark(_ provider: Provider) -> NSImage? {
        let name: String
        switch provider.kind {
        case .chatGPT: name = "OpenAIMark"
        case .claudeCode: name = "ClaudeMark"
        case .api(let preset):
            guard let preset = preset.flatMap(ProviderPreset.init(id:)) else { return symbol("server.rack") }
            name = preset.logoAsset
        }
        guard let copy = NSImage(named: name)?.copy() as? NSImage else { return symbol("server.rack") }
        copy.size = NSSize(width: 16, height: 16)
        copy.isTemplate = true
        return copy
    }

    private static func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
}

/// The menu's first line: whether a fix would work and with which model, then the tally.
@MainActor final class StatusLine: ObservableObject {
    @Published var title = ""
    @Published var subtitle: String?
    @Published var image: NSImage?
}

/// Drawn like a menu item (its image and title columns) but never dimmed: it isn't something to click.
struct StatusLineView: View {
    @ObservedObject var model: StatusLine

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let image = model.image {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: NSFont.systemFontSize))
                if let subtitle = model.subtitle {
                    Text(subtitle).font(.system(size: NSFont.smallSystemFontSize)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 14).padding(.trailing, 14).padding(.vertical, 4)
        .frame(minWidth: 220, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
