import AppKit
import ApplicationServices
import OSLog

/// The Chromium accessibility switches Oops has set and not yet restored, mirrored to disk. A crash
/// mid-correction would otherwise leave an app building its full accessibility tree, costing it CPU,
/// until it quits: the next launch turns off whatever a previous run left on.
final class AccessibilitySwitches: @unchecked Sendable {
    private struct Entry: Codable, Equatable { let attribute: String; let launched: Double? }
    private static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Highlight")
    private let lock = NSLock()
    private var entries: [pid_t: Entry] = [:]
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("oops/accessibility-switches.json")

    func record(_ attribute: String, pid: pid_t) {
        let launched = NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970
        lock.withLock { entries[pid] = Entry(attribute: attribute, launched: launched); save() }
    }

    /// The switch set on `pid`, still recorded.
    func attribute(for pid: pid_t) -> String? { lock.withLock { entries[pid]?.attribute } }

    /// The switch set on `pid`, forgotten.
    func take(_ pid: pid_t) -> String? {
        lock.withLock {
            defer { save() }
            return entries.removeValue(forKey: pid)?.attribute
        }
    }

    /// Turns every recorded switch off: this run's at quit, a crashed run's at launch. A process that
    /// has since quit, or whose pid now belongs to another launch, is dropped. One that doesn't read
    /// back as off (slow to answer, Accessibility missing) stays recorded for the next quit or launch.
    func restoreAll() {
        let pending: [pid_t: Entry] = lock.withLock {
            var all = entries
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([pid_t: Entry].self, from: data) {
                all.merge(saved) { current, _ in current }
            }
            return all
        }
        var remaining: [pid_t: Entry] = [:]
        for (pid, entry) in pending {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { continue }
            if let launched = entry.launched, let now = app.launchDate?.timeIntervalSince1970, abs(now - launched) > 1 { continue }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            let result = AXUIElementSetAttributeValue(element, entry.attribute as CFString, kCFBooleanFalse)
            // Chrome answers "unsupported" and applies it anyway: read it back.
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, entry.attribute as CFString, &value)
            let off = (value as? NSNumber)?.boolValue == false
            Self.log.notice("accessibility_switch_restored attribute=\(entry.attribute, privacy: .public) result=\(result.rawValue, privacy: .public) off=\(off, privacy: .public)")
            if !off { remaining[pid] = entry }
        }
        lock.withLock {
            // Switches recorded while this ran are kept too.
            for (pid, entry) in pending where entries[pid] == entry { entries.removeValue(forKey: pid) }
            entries.merge(remaining) { current, _ in current }
            save()
        }
    }

    /// Called with the lock held.
    private func save() {
        if entries.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
