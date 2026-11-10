import AppKit
import OopsCore
import Synchronization

/// Save every materialized representation. Restore only while our entry still owns the pasteboard.
/// Taken on the Accessibility queue and given back on the main actor: the entry it owns is behind a mutex.
final class ClipboardLease: Sendable {
    private let saved: [[NSPasteboard.PasteboardType: Data]]
    private let capturedCount: Int
    private let ownership = Mutex<Int?>(nil)
    private static let unreadableAliases: Set = ["Apple Web Archive pasteboard type", "iOS rich content paste pasteboard type"]
    init() throws {
        let board = NSPasteboard.general
        capturedCount = board.changeCount
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in board.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    // Legacy aliases Notes copies beside the readable types they stand for: no app can read
                    // them, so there's nothing of them to save.
                    if Self.unreadableAliases.contains(type.rawValue) { continue }
                    throw CorrectionError.message("The clipboard contains data that cannot be safely saved. Nothing replaced.")
                }
                representations[type] = data
            }
            saved.append(representations)
        }
        self.saved = saved
        guard board.changeCount == capturedCount else { throw CorrectionError.message("The clipboard changed while preparing the correction. Try again.") }
    }
    /// Puts `text` on the pasteboard, once per span, as long as nobody else wrote to it since; with `rtf`
    /// beside it when the paste carries formatting.
    func install(_ text: String, rtf: Data? = nil) throws {
        let board = NSPasteboard.general
        guard board.changeCount == ownership.withLock({ $0 }) ?? capturedCount else { throw CorrectionError.message("The clipboard changed. Nothing replaced.") }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let rtf { item.setData(rtf, forType: .rtf) }
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item]); ownership.withLock { $0 = board.changeCount }
    }
    /// Takes what an app just copied (at Oops's own ⌘C) as Oops's entry: it may be replaced, and the
    /// saved clipboard comes back over it.
    func adopt() { ownership.withLock { $0 = NSPasteboard.general.changeCount } }

    func restoreIfOwned() {
        let board = NSPasteboard.general
        guard let owned = ownership.withLock({ $0 }), board.changeCount == owned else { return }
        board.clearContents()
        let items = saved.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
    func requireOwnership() throws {
        guard let owned = ownership.withLock({ $0 }), NSPasteboard.general.changeCount == owned else {
            throw CorrectionError.message("The clipboard changed before paste. Nothing replaced.")
        }
    }
}
