import AppKit
import Observation

/// The apps Oops has corrected in, and those it is turned off in, by bundle identifier
/// (Settings → General, and the menu bar menu).
@MainActor @Observable final class AppScope {
    static let shared = AppScope()
    private nonisolated static let key = "TurnedOffApps"
    private static let usedKey = "UsedApps"
    private(set) var turnedOff: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []
    /// Most recent first.
    private(set) var used: [String] = UserDefaults.standard.stringArray(forKey: usedKey) ?? []

    /// Every app with a switch: used ones, then any turned off without having been used.
    var apps: [String] { used + turnedOff.filter { !used.contains($0) } }

    func isOn(_ bundleID: String) -> Bool { !turnedOff.contains(bundleID) }

    func set(_ bundleID: String, on: Bool) {
        turnedOff.removeAll { $0 == bundleID }
        if !on { turnedOff.append(bundleID) }
        UserDefaults.standard.set(turnedOff, forKey: Self.key)
    }

    func noteUsed(_ bundleID: String) {
        guard used.first != bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        used.removeAll { $0 == bundleID }
        used.insert(bundleID, at: 0)
        UserDefaults.standard.set(used, forKey: Self.usedKey)
    }

    /// The same list, for capture on the Accessibility queue.
    nonisolated static var current: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func name(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    static func icon(_ bundleID: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
    }
}
