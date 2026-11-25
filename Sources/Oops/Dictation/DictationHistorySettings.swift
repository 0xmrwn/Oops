import Foundation
import Observation
import OopsCore
import os

extension DictationHistoryRetention {
    /// Where Settings keeps the retention, by raw value.
    static let key = "DictationHistory"
    /// The retention as saved, 7 days until one is chosen.
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .week
    }

    /// The Keep for menu's choices, in its order.
    static let choices: [(value: Self, label: String)] = [(.day, "1 day"), (.week, "7 days"), (.month, "30 days"), (.off, "Off")]
}

/// The app's dictation history: one store under Application Support, opened (and so expired) the first time it is
/// touched, which the dictation session's setup does at launch. Views read `revision`, so a change or a sweep
/// refreshes them. Nothing here logs a dictation's words.
@MainActor @Observable final class DictationHistoryModel {
    static let shared = DictationHistoryModel(file: defaultFile)
    static let recentCount = 5
    private static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "DictationHistory")

    /// Moves after every change and every sweep that expired something.
    private(set) var revision = 0
    /// Show all…: Settings opens on the History page.
    var wantsPage = false
    /// Writes an entry at the caret of the app Settings covered; set by the app with the dictation session.
    @ObservationIgnored var insert: (@MainActor (String) -> Void)?
    @ObservationIgnored private let history: DictationHistory
    @ObservationIgnored private let defaults: UserDefaults
    /// The entry the last record created, saved or not, which "Clean up with AI" replaces, and its whole text: the
    /// entry keeps at most 16 KiB, and an unsaved one is gone at relaunch.
    @ObservationIgnored private var last: (id: Int, text: String)?

    /// `Application Support/oops/History/dictations.json`; `-DictationHistoryDirectory` moves it in debug runs.
    static var defaultFile: URL {
        let folder = DebugFlags.dictationHistoryDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oops/History")
        return folder.appendingPathComponent("dictations.json")
    }

    init(file: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The sweep runs off the main actor: it only signals, and the model refreshes here.
        let (sweeps, sweep) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        history = DictationHistory(store: DictationHistoryStore(file: file, retention: .saved(in: defaults), now: DictationHistory.now()),
                                   onSweep: { sweep.yield() })
        Task { [weak self] in
            for await _ in sweeps { self?.changed() }
        }
    }

    var retention: DictationHistoryRetention {
        get {
            _ = revision
            return history.retention
        }
        set {
            defaults.set(newValue.rawValue, forKey: DictationHistoryRetention.key)
            do { try history.setRetention(newValue) } catch { Self.log.warning("could not save the history's retention (\(Self.describe(error), privacy: .public))") }
            changed()
        }
    }

    /// Keeps a finished dictation, unless retention is Off. A failed save is logged, without the words.
    func record(text: String, language: String?, model: String?, application: String?, bundleID: String?, durationMs: Int) {
        do {
            last = try history.record(DictationHistoryDraft(text: text, application: application, bundleID: bundleID, model: model, language: language,
                                                            durationMs: durationMs))
                .map { ($0, text) }
        } catch {
            // A failed save still keeps the entry in memory, as the newest.
            last = history.recent(1).first.map { ($0.id, text) }
            Self.log.warning("could not save a dictation length=\(text.utf16.count, privacy: .public) (\(Self.describe(error), privacy: .public))")
        }
        changed()
    }

    /// Replaces the text of the entry the last record created, if there is one.
    func replaceLast(_ text: String) {
        guard let id = last?.id else { return }
        do { if try history.replaceText(of: id, with: text) { last?.text = text } } catch {
            Self.log.warning("could not save a cleaned dictation id=\(id, privacy: .public) (\(Self.describe(error), privacy: .public))")
        }
        changed()
    }

    /// What Paste last dictation writes: with retention Off, the dictation held in memory; otherwise the newest entry,
    /// so it survives a relaunch, and a cleared or deleted dictation isn't pasted from memory. While that entry is the
    /// last one recorded, its whole text, as held here: saved or not, and past the entry's cap.
    func lastText(inMemory: String?) -> String? {
        if retention.isOff { return inMemory }
        guard let newest = history.recent(1).first else { return nil }
        return newest.id == last?.id ? last?.text : newest.text
    }

    func entries(matching query: String) -> [DictationHistoryEntry] {
        _ = revision
        return history.search(query)
    }

    func recent() -> [DictationHistoryEntry] {
        _ = revision
        return history.recent(Self.recentCount)
    }

    func text(of id: Int) -> String? { history.text(of: id) }

    func delete(_ id: Int) throws {
        defer { changed() }
        try history.delete(id)
    }

    func clear() throws {
        defer { changed() }
        try history.clear()
    }

    private func changed() { revision &+= 1 }

    /// An error's domain and code only: a decoding error can quote the file's words.
    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
