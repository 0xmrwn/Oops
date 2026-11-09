import AppKit
import ApplicationServices

/// The permission Oops reads and edits drafts with, and what System Settings calls its list.
enum AccessibilityPermission {
    static let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
    /// What System Settings calls the list: macOS 27 renamed it (checked on 27.0).
    nonisolated static var paneName: String { renamedPane ? "Device Control and Data Access" : "Accessibility" }
    /// The symbol on the pane's blue tile: 27's `privacy-accessibility` icon in Privacy & Security's
    /// Info.plist, and the Accessibility figure before it.
    nonisolated static var paneSymbol: String { renamedPane ? "folder.badge.gearshape" : "accessibility" }

    private nonisolated static var renamedPane: Bool {
        if #available(macOS 27, *) { !DebugFlags.onboardingOlderPane } else { false }
    }

    /// Whether Oops is allowed. Removed from the list while it runs, `AXIsProcessTrusted()` can go on
    /// answering yes until Oops restarts, while every Accessibility call already fails as disabled: ask
    /// the Dock something too, which answers at once when allowed.
    nonisolated static var granted: Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return true }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) != .apiDisabled
    }
}
