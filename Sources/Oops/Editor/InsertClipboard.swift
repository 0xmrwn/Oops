import AppKit
import OopsCore
import Synchronization

/// The clipboard side of an insert: the text goes through the pasteboard as one transient item, and
/// what was there comes back half a second after the paste, only while the pasteboard still holds
/// that item. Something copied meanwhile is newer, and stays. The rules are Hex's (`ClipboardRestore`),
/// over the lease Fix saves and restores the clipboard with.
final class InsertClipboard: Sendable {
    struct Prepared: Sendable { let lease: ClipboardLease; let changeCount: Int }
    private let name: NSPasteboard.Name
    private let pending = Mutex(ClipboardRestore<ClipboardLease>())

    init(board name: NSPasteboard.Name = .general) { self.name = name }

    /// Saves the clipboard. While it still holds the last insert's text, that insert's lease is the
    /// one to write through: what it saved is the person's clipboard.
    func prepare() throws -> Prepared {
        let count = NSPasteboard(name: name).changeCount
        let held = pending.withLock { $0.lastChangeCount == count ? $0.original : nil }
        return Prepared(lease: try held ?? ClipboardLease(board: name), changeCount: count)
    }

    /// Puts `text` on the pasteboard, unless it changed since `prepare`. Returns the generation to restore under.
    func write(_ text: String, through prepared: Prepared) throws -> UInt64 {
        try prepared.lease.install(text, generated: true)
        let inserted = NSPasteboard(name: name).changeCount
        return pending.withLock { $0.register(prepared.lease, previousChangeCount: prepared.changeCount, insertedChangeCount: inserted) }
    }

    /// Gives the saved clipboard back, if this insert is still the latest and its text is still what the pasteboard holds.
    func restore(_ generation: UInt64) {
        let count = NSPasteboard(name: name).changeCount
        pending.withLock { $0.take(generation: generation, changeCount: count) }?.restoreIfOwned()
    }

    func scheduleRestore(_ generation: UInt64) {
        Task.detached { [self] in
            try? await Task.sleep(for: PasteSequence.restoreDelay)
            restore(generation)
        }
    }
}
