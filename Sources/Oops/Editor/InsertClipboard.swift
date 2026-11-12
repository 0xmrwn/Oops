import AppKit
import OopsCore
import Synchronization

/// The clipboard side of an insert: the text goes through the pasteboard as one transient item, and
/// what was there comes back half a second after the paste, only while the pasteboard still holds
/// that item. Something copied meanwhile is newer, and stays. The rules are Hex's (`ClipboardRestore`),
/// over the lease Fix saves and restores the clipboard with.
final class InsertClipboard: Sendable {
    private let name: NSPasteboard.Name
    private let pending = Mutex(ClipboardRestore<ClipboardLease>())

    init(board name: NSPasteboard.Name = .general) { self.name = name }

    /// Saves the clipboard, asks `commit`, then puts `text` on the pasteboard unless it changed since it
    /// was saved; returns the generation to restore under. While the pasteboard still holds the last
    /// insert's text, that insert's lease is the one to write through: what it saved is the person's
    /// clipboard. The lock is held throughout, as Hex holds its restore state from the save to the write:
    /// the last insert's restore waits, rather than take the pasteboard from under this one.
    func paste(_ text: String, commit: () -> Bool = { true }) throws -> UInt64 {
        let board = NSPasteboard(name: name)
        return try pending.withLock { state in
            let count = board.changeCount
            let held = state.lastChangeCount == count ? state.original : nil
            return try PasteSequence.commitPrepared(prepare: { try held ?? ClipboardLease(board: name) }, commit: commit) { lease in
                try lease.install(text, generated: true)
                return state.register(lease, previousChangeCount: count, insertedChangeCount: board.changeCount)
            }
        }
    }

    /// Gives the saved clipboard back, if this insert is still the latest and its text is still what the pasteboard holds.
    func restore(_ generation: UInt64) {
        let board = NSPasteboard(name: name)
        pending.withLock { state in
            let saved = state.take(generation: generation, changeCount: board.changeCount)
            saved?.restoreIfOwned()
        }
    }

    /// Gives it back now rather than at its timer: Fix is about to save the clipboard, and would take
    /// an insert's text for the person's.
    func settle() {
        let latest = pending.withLock { $0.generation }
        restore(latest)
    }

    func scheduleRestore(_ generation: UInt64) {
        Task.detached { [self] in
            try? await Task.sleep(for: PasteSequence.restoreDelay)
            restore(generation)
        }
    }
}
