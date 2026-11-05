import AppKit
import SwiftUI

/// The Settings window: built once, shown in the middle of the screen the pointer is on, and the
/// app becomes a regular one (Dock icon, Command-Tab) only while it is open.
@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    private let preferences: Preferences
    private let testEditor: TestEditorModel
    private let session: CorrectionSession?
    private var window: NSWindow?
    private var backdrop: NSWindow?

    init(preferences: Preferences, testEditor: TestEditorModel, session: CorrectionSession?) {
        self.preferences = preferences; self.testEditor = testEditor; self.session = session
    }

    /// Fix and Restore target the Try page's draft only while it is what Settings shows.
    var tryIsActive: Bool { window?.isKeyWindow == true && testEditor.presented }

    func show() {
        let window = window ?? makeWindow()
        if !window.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: (visible.midX - window.frame.width / 2).rounded(),
                                              y: (visible.midY - window.frame.height / 2).rounded()))
            }
        }
        if DebugFlags.perfHarness != nil { window.orderFrontRegardless() } else {
            NSApp.enterDock()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
        updateBackdrop()
    }

    /// General → Try.
    func showTry() {
        testEditor.requested = true
        show()
    }

    /// Try's buttons act on its own draft: capture reads the system-wide focus, so the window and the
    /// editor take it first. Activation is asynchronous; wait briefly until it lands.
    func focusTry() async {
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        testEditor.editor?.focus()
        await Task.yield()
        for _ in 0..<40 where !(NSApp.isActive && window?.isKeyWindow == true) {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func makeWindow() -> NSWindow {
        let style = SettingsStyle(variant: .current, opaque: SettingsStyle.forcesOpaque)
        let view = SettingsView(preferences: preferences, testEditor: testEditor,
                                preview: { [weak self] in self?.session?.preview() },
                                previewPlacement: { [weak self] in await self?.session?.previewPlacement() ?? "" },
                                clearFocus: { [weak self] in self?.window?.makeFirstResponder(nil) })
            .environment(\.settingsStyle, style)
            .focusRingsFromKeyboard()
        let controller = NSHostingController(rootView: view)
        // One fixed size for every page: long pages scroll, short ones show the eyes.
        controller.sizingOptions = []
        let window = FocusRingsWindow(contentViewController: controller)
        window.title = "Oops"; window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        // The header names the app; the title stays only for the Window menu and VoiceOver. An empty
        // unified toolbar gives the traffic lights the toolbar inset, concentric with the window's
        // large corner radius, instead of the title bar's corner-hugging spot.
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "oops.settings")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        // One native enclosure, with the hosting view inside its content layer: a sidebar blur plus
        // opaque SwiftUI fills flattens the optical glass edges.
        let enclosure = SettingsGlassEnclosure()
        enclosure.variant = style.variant
        enclosure.forcesOpaque = style.opaque
        enclosure.cornerRadius = 26
        enclosure.contentView = controller.view
        window.contentView = SettingsWindowBackdrop(enclosure: enclosure)
        window.setContentSize(NSSize(width: 620, height: SettingsView.height))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        if let appearance = DebugFlags.settingsAppearance {
            window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        window.isReleasedWhenClosed = false
        self.window = window
        return window
    }

    func windowDidResize(_ notification: Notification) { updateBackdrop() }
    func windowDidMove(_ notification: Notification) { updateBackdrop() }
    /// Closing releases the window and its views, so a closed Settings costs no memory or wakeups;
    /// opening builds it again.
    func windowWillClose(_ notification: Notification) {
        #if DEBUG
        if DebugFlags.brandReview { DispatchQueue.main.async { NSApp.terminate(nil) } }
        #endif
        backdrop?.orderOut(nil); backdrop = nil
        testEditor.presented = false
        if let window { NSApp.leaveDockUnlessOtherWindows(than: window) }
        DispatchQueue.main.async { [weak self] in self?.window?.contentViewController = nil; self?.window = nil }
    }

    /// Debug captures: a colourful window kept just behind Settings, so screenshots show the glass
    /// over a known backdrop instead of the user's own windows.
    private func updateBackdrop() {
        guard DebugFlags.backdrop, let window, window.isVisible else { return }
        let backdrop = backdrop ?? {
            let backdrop = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.contentView = NSHostingView(rootView: SettingsPreviewBackdrop())
            backdrop.isReleasedWhenClosed = false
            backdrop.ignoresMouseEvents = true
            backdrop.hasShadow = false
            self.backdrop = backdrop
            return backdrop
        }()
        backdrop.setFrame(window.frame.insetBy(dx: -120, dy: -320), display: true)
        backdrop.order(.below, relativeTo: window.windowNumber)
    }
}
