import Foundation

// The clipboard rules of a paste that writes new text (an insert), ported from Hex
// (github.com/anomalyco/hex, `src/paste.rs` at 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton):
// `ClipboardRestore`, `commit_prepared_paste` and `complete_paste`.

/// Which saved clipboard comes back after a paste, and whether it still should. Each paste registers
/// the clipboard it saved and schedules its own restore; only the latest paste's restore acts, and
/// only while the pasteboard still holds what that paste wrote.
public struct ClipboardRestore<Snapshot> {
    public private(set) var generation: UInt64 = 0
    /// The clipboard as it was before the first of the pastes still pending.
    public private(set) var original: Snapshot?
    /// The pasteboard's change count once the latest paste wrote its text.
    public private(set) var lastChangeCount: Int?

    public init() {}

    /// A paste wrote its text: `previous` is the clipboard it saved at `previousChangeCount`. When that
    /// was still the last paste's own text, the clipboard saved before it stays the original, so rapid
    /// pastes give back what was there before the first. Returns the paste's generation, for its restore.
    public mutating func register(_ previous: Snapshot, previousChangeCount: Int, insertedChangeCount: Int) -> UInt64 {
        generation &+= 1
        if lastChangeCount != previousChangeCount { original = previous }
        lastChangeCount = insertedChangeCount
        return generation
    }

    /// The clipboard to put back when the restore scheduled by paste `generation` fires, with the
    /// pasteboard at `changeCount`. Nil when a later paste took over (its restore will act), or when
    /// the pasteboard no longer holds what the paste wrote: what is there is newer, and stays.
    public mutating func take(generation: UInt64, changeCount: Int) -> Snapshot? {
        guard self.generation == generation else { return nil }
        guard lastChangeCount == changeCount else { original = nil; lastChangeCount = nil; return nil }
        guard let previous = original else { return nil }
        original = nil; lastChangeCount = nil
        return previous
    }
}

extension ClipboardRestore: Sendable where Snapshot: Sendable {}

/// The order a paste's steps run in.
public enum PasteSequence {
    /// How long the pasteboard is left alone after ⌘V, for the target to read it. Not an
    /// acknowledgement: a longer stall in the system or the app can still lose a paste.
    public static let settle: Duration = .milliseconds(100)
    /// How long after ⌘V the saved clipboard comes back.
    public static let restoreDelay: Duration = .milliseconds(500)

    /// The paste was called off after its preparation: nothing was written.
    public struct Cancelled: Error, Equatable { public init() {} }

    /// Commits only after the clipboard is saved, immediately before the first write. Saving the
    /// clipboard stays cancellable; once committed, even a failed write may have changed it.
    public static func commitPrepared<Prepared, Output>(prepare: () throws -> Prepared, commit: () -> Bool,
                                                        paste: (Prepared) throws -> Output) throws -> Output {
        let prepared = try prepare()
        guard commit() else { throw Cancelled() }
        return try paste(prepared)
    }

    /// Posts the paste, schedules the restore whether or not the post worked (the text is on the
    /// pasteboard either way), then leaves the pasteboard alone for `settle`.
    public static func complete(post: () throws -> Void, scheduleRestore: () -> Void, wait: (Duration) -> Void) throws {
        let posted = Result { try post() }
        scheduleRestore()
        try posted.get()
        wait(settle)
    }
}
