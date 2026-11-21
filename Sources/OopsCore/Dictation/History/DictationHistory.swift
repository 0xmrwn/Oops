import Foundation
import os

// The shared handle over one dictation history store, ported from Hex (github.com/anomalyco/hex, `History` in
// `src/history.rs` at v3.4.0; MIT, Copyright (c) 2026 Christopher Langton). See THIRD_PARTY_NOTICES.md. Left out:
// `sync` before each call (one process), recordings and versions, and `search_at`. Departures: `text(of:)` is nil
// once the entry is past retention, where Hex's `final_text` returns it until the sweep prunes it; the sweep reports
// back through `onSweep`, so the menu and the History page can refresh.

/// Thread-safe shared handle with the retention sweep. The sweep stops when the last reference to the handle goes.
public final class DictationHistory: @unchecked Sendable {
    /// Hex's `PRUNE_INTERVAL`.
    public static let sweepInterval: TimeInterval = 60

    private let state: OSAllocatedUnfairLock<DictationHistoryStore>
    private let clock: @Sendable () -> Int
    private let onSweep: (@Sendable () -> Void)?
    private let timer: any DispatchSourceTimer

    /// Wall clock, in milliseconds since 1970.
    public static func now() -> Int { Int(Date().timeIntervalSince1970 * 1_000) }

    public init(store: DictationHistoryStore, interval: TimeInterval = DictationHistory.sweepInterval,
                clock: @escaping @Sendable () -> Int = DictationHistory.now, onSweep: (@Sendable () -> Void)? = nil) {
        state = OSAllocatedUnfairLock(initialState: store)
        self.clock = clock
        self.onSweep = onSweep
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "oops.DictationHistory", qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(Int(interval * 100_000_000)))
        // Weak, so the timer never keeps the handle alive.
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// Hex's `try_lock`: a busy store skips the tick. `clock` is sampled under the lock.
    private func sweep() {
        let clock = clock
        let changed = state.withLockIfAvailable { store -> Bool in
            let before = store.revisionCounter
            store.expire(now: clock())
            return store.revisionCounter != before
        }
        if changed == true { onSweep?() }
    }

    /// Runs `body` on the store under the lock.
    func locked<T: Sendable>(_ body: @Sendable (inout DictationHistoryStore) throws -> T) rethrows -> T {
        try state.withLock(body)
    }

    public var retention: DictationHistoryRetention { locked { $0.retention } }

    public func setRetention(_ retention: DictationHistoryRetention) throws {
        let clock = clock
        try locked { try $0.setRetention(retention, now: clock()) }
    }

    @discardableResult public func record(_ draft: DictationHistoryDraft) throws -> Int? {
        let clock = clock
        return try locked { try $0.record(draft, now: clock()) }
    }

    @discardableResult public func delete(_ id: Int) throws -> Bool { try locked { try $0.delete(id) } }

    @discardableResult public func replaceText(of id: Int, with text: String) throws -> Bool { try locked { try $0.replaceText(of: id, with: text) } }

    public func clear() throws { try locked { try $0.clear() } }

    /// Bounded snapshot of matching entries, newest first. As Hex's, it prunes in memory first (through `revision`);
    /// the sweep saves that prune.
    public func search(_ query: String) -> [DictationHistoryEntry] {
        let clock = clock
        return locked { store in
            let now = clock()
            _ = store.revision(now: now)
            return store.search(query, now: now)
        }
    }

    public func recent(_ count: Int) -> [DictationHistoryEntry] {
        let clock = clock
        return locked { $0.recent(count, now: clock()) }
    }

    /// The text of entry `id` (Hex's `final_text`); nil once it is expired or deleted.
    public func text(of id: Int) -> String? {
        let clock = clock
        return locked { store in
            let cutoff = store.cutoff(now: clock())
            return store.entries.first { $0.id == id && $0.timestampMs >= cutoff }?.text
        }
    }

    public func revision() -> Int {
        let clock = clock
        return locked { $0.revision(now: clock()) }
    }
}
