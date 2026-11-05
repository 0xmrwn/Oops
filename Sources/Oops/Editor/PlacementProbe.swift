import AppKit
import ApplicationServices
import OopsCore

/// Diagnostics for capsule placement: where the focused text box and caret are, per engine.
/// Records geometry, ranges and lengths only, never text, as JSON lines in
/// `Application Support/oops/Diagnostics/placement.jsonl` (0600).
@MainActor final class PlacementProbe: ObservableObject {
    @Published private(set) var countdown: Int?
    @Published private(set) var summary = ""
    /// Chromium builds its accessibility tree lazily. Electron apps take `AXManualAccessibility`;
    /// Chrome and WebView2 take `AXEnhancedUserInterface`, the switch VoiceOver sets.
    enum Mode: String, CaseIterable, Identifiable {
        case plain, manual, enhanced
        var id: String { rawValue }
        var title: String {
            switch self { case .plain: "Off"; case .manual: "AXManualAccessibility"; case .enhanced: "AXEnhancedUserInterface" }
        }
        var attribute: String? {
            switch self { case .plain: nil; case .manual: "AXManualAccessibility"; case .enhanced: "AXEnhancedUserInterface" }
        }
    }
    @Published var mode: Mode = .plain
    static let log = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("oops/Diagnostics/placement.jsonl")
    private var task: Task<Void, Never>?

    /// Gives the owner time to focus another app's composer, then previews the capsule there.
    func start(_ preview: @escaping @MainActor () async -> String) {
        countdown { [weak self] in self?.summary = await preview() }
    }
    /// Gives the owner time to focus another app's composer before sampling it.
    func start() {
        let mode = mode
        countdown { [weak self] in self?.summary = await Self.record(mode: mode) }
    }
    /// Samples the focused editor now and appends the record; also the debug trigger's entry.
    static func record(mode: Mode) async -> String {
        let screens = NSScreen.screens.map { ["frame": json($0.frame), "visible": json($0.visibleFrame), "scale": $0.backingScaleFactor] }
        var record = await sample(mode: mode)
        record["screens"] = screens
        do { try append(record) } catch { return "Could not write the probe log." }
        return summarize(record)
    }
    private func countdown(then run: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            for remaining in stride(from: 5, to: 0, by: -1) {
                self?.countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.countdown = nil
            await run()
        }
    }
    func cancel() { task?.cancel(); countdown = nil }
    func revealLog() {
        if FileManager.default.fileExists(atPath: Self.log.path) { NSWorkspace.shared.activateFileViewerSelecting([Self.log]) }
        else { summary = "No probes recorded yet." }
    }

    /// Logs what a placement preview used and produced, for checking the engine against fixtures.
    static func recordPreview(_ geometry: CapsulePlacement.Geometry, _ placement: CapsulePlacement.Placement) {
        var record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "mode": "preview",
                                     "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                                     "strategy": placement.strategy.rawValue, "envelope": json(placement.envelope)]
        record["element"] = geometry.element.map(json)
        record["ancestors"] = geometry.ancestors.map { ["role": $0.role, "frame": json($0.frame)] }
        record["ax_window"] = geometry.window.map(json)
        record["caret"] = geometry.caret.map(json)
        record["previous_character"] = geometry.previousCharacter.map(json)
        try? append(record)
    }
    private static func append(_ record: [String: Any]) throws {
        let fm = FileManager.default, directory = log.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); line.append(0x0A)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
    }

    private static func summarize(_ record: [String: Any]) -> String {
        if let error = record["error"] as? String { return error }
        let box = (record["element"] as? [String: Any])?["frame"] as? [Double]
        func found(_ key: String) -> String { (record["caret"] as? [String: Any])?[key] is [Double] ? "yes" : "no" }
        let size = box.map { "\(Int($0[2]))×\(Int($0[3]))" } ?? "none"
        let words = record["words"] as? [[String: Any]] ?? []
        func usable(_ key: String) -> Int { words.filter { ($0[key] as? [Double]).map { $0[2] > 0 && $0[3] > 0 } ?? false }.count }
        let lines = (words.first?["line"] as? Int).map { _ in "yes" } ?? "no"
        return "\(record["bundle"] as? String ?? "unknown") · box \(size) · caret by range: \(found("range")), by text marker: \(found("marker"))"
            + " · word rects by range: \(usable("range_rect"))/\(words.count), by marker: \(usable("marker"))/\(words.count), lines: \(lines)"
    }
}
