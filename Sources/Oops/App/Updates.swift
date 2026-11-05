import AppKit
import Observation
import os
import Sparkle

/// Where an update stands. Sparkle (D2) checks the feed once a day and drives these states through
/// `UpdateDriver`; About shows them, with no Sparkle window. Downloads wait for Update: nothing is
/// fetched or installed behind the user's back. A bundle without a feed (development builds) never
/// checks. The preview (`-SettingsPreviewUpdate available|downloading|ready|failed`, Debug only) walks
/// the flow with a made-up release, without Sparkle.
@MainActor @Observable final class Updates {
    struct Release: Equatable {
        let version: String
        /// Plain-language notes, the same style as CHANGELOG.md entries.
        var notes: [String]
        /// Set when the feed only points to a web page (Sparkle's informational update): Update opens it.
        var page: URL?
    }
    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Release, progress: Double)
        case ready(Release)
        case failed(String)
    }

    static let shared = Updates()
    /// The update test's copy of Oops (`script/test_update.py`): its own defaults, Keychain and
    /// permissions, a localhost feed, and nothing but the updater running (`runHarness`).
    static let harnessIdentifier = "dev.0xmrwn.oops.update-test"
    static var isHarness: Bool { Bundle.main.bundleIdentifier == harnessIdentifier }

    /// Set by `UpdateDriver` as Sparkle reports, and by the preview.
    private(set) var state: State = .idle
    let preview: Bool
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private let driver = UpdateDriver()
    @ObservationIgnored private var flow: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.0xmrwn.oops", category: "Updates")

    private static let sample = Release(version: "0.2.0", notes: [
        "Fix only the sentence you're in with a second shortcut.",
        "Pick a different model for each app.",
        "Stats show your busiest hours.",
    ])

    private init() {
        let mode = DebugFlags.update
        preview = mode != nil
        switch mode {
        case "available": state = .available(Self.sample)
        case "downloading": state = .downloading(Self.sample, progress: 0.45)
        case "ready": state = .ready(Self.sample)
        case "failed": state = .failed("The update couldn’t be downloaded.")
        default: break
        }
    }

    /// Starts Sparkle's daily schedule, when this bundle carries a feed (release builds).
    func start() {
        guard !preview, updater == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        driver.updates = self
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            log.error("updater: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The update test's copy: only the updater, which checks at once and accepts each step itself,
    /// so the test needs no input. The relaunched copy runs this too, finding nothing newer.
    func runHarness() {
        start()
        updater?.checkForUpdatesInBackground()
    }

    /// Whether Check for Updates can do anything now.
    var canCheck: Bool { preview || updater != nil }

    /// The release waiting to be installed, if any.
    var pending: Release? {
        switch state {
        case .available(let release), .downloading(let release, _), .ready(let release): release
        default: nil
        }
    }

    func check() {
        guard preview else { updater?.checkForUpdates(); return }
        run {
            self.state = .checking
            try await Task.sleep(for: .seconds(1.2))
            self.state = .available(Self.sample)
        }
    }

    func install() {
        guard let release = pending else { return }
        guard preview else {
            if let page = release.page {
                NSWorkspace.shared.open(page)
                driver.answer(.dismiss)
                show(.idle)
            } else {
                show(.downloading(release, progress: 0))
                driver.answer(.install)
            }
            return
        }
        run {
            for step in 0...20 {
                self.state = .downloading(release, progress: Double(step) / 20)
                try await Task.sleep(for: .milliseconds(120))
            }
            self.state = .ready(release)
        }
    }

    /// Sparkle quits Oops, swaps the bundle and opens the new version; the preview starts over.
    func relaunch() {
        guard preview else { driver.answer(.install); return }
        flow?.cancel(); state = .upToDate
    }

    func show(_ new: State) {
        guard new != state else { return }
        let step = Self.step(state)
        state = new
        guard Self.step(new) != step else { return }
        log.notice("state: \(Self.step(new), privacy: .public)")
        guard Self.isHarness else { return }
        // Answered on the next turn, never from inside the Sparkle call that asked.
        switch new {
        case .available: DispatchQueue.main.async { self.install() }
        case .ready: DispatchQueue.main.async { self.relaunch() }
        default: break
        }
    }

    /// A state without its progress: one log line per step.
    private static func step(_ state: State) -> String {
        switch state {
        case .idle: "idle"
        case .checking: "checking"
        case .upToDate: "up to date"
        case .available(let release): "available \(release.version), \(release.notes.count) notes"
        case .downloading(let release, _): "downloading \(release.version)"
        case .ready(let release): "ready \(release.version)"
        case .failed(let message): "failed: \(message)"
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        flow?.cancel()
        flow = Task { try? await body() }
    }
}
