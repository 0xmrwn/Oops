import Foundation
import os

// The store's file handling, ported from Hex's `open`, `persist`, `preserve_corrupt` and `truncated` (see
// DictationHistoryStore.swift). Departures: the folder is created 0o700 as DebugLogStore does, and the temporary file
// is created 0o600 before a byte is written, where Hex restricts it after create. The malformed copy and the
// temporary file are named by appending to the file's name, which is Hex's `history.json.corrupt` for `history.json`.

extension DictationHistoryStore {
    /// The file's content: `{ "version": 1, "nextID": …, "entries": […] }`.
    struct Saved: Codable {
        var version: Int
        var nextID: Int
        var entries: [DictationHistoryEntry]
    }

    /// Never logs more than an error's domain and code: a decoding error can quote the file's words.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// Reads the file. Missing is empty; malformed or an unsupported version is preserved and starts empty; any other
    /// read error starts empty and leaves the file.
    mutating func load() {
        let data: Data
        do { data = try Data(contentsOf: file) } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            Self.log.warning("could not read the dictation history (\(Self.describe(error), privacy: .public))")
            return
        }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            Self.log.warning("the dictation history is malformed; keeping a copy and starting empty")
            preserveCorrupt()
            return
        }
        guard saved.version == Self.version else {
            Self.log.warning("the dictation history has an unsupported version \(saved.version); keeping a copy and starting empty")
            preserveCorrupt()
            return
        }
        nextID = max(saved.nextID, (saved.entries.map(\.id).max() ?? 0) + 1)
        entries = saved.entries.sorted { $0.id < $1.id }
    }

    /// Saves the entries. Every change to them goes through here, so it moves the revision whether or not the save
    /// works (a failed save may keep the change, as a record does, or roll it back).
    mutating func persist() throws {
        touch()
        let json = try JSONEncoder().encode(Saved(version: Self.version, nextID: nextID, entries: entries))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = Self.sibling(of: file, suffix: ".tmp")
        // O_TRUNC and the fchmod cover a leftover from a crash; both come before the first byte.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fchmod(descriptor, 0o600) == 0 else { throw Self.posixError() }
        try handle.write(contentsOf: json)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw Self.posixError() }
        prunePending = false
        pruneErrorReported = false
    }

    func preserveCorrupt() {
        if rename(file.path, Self.sibling(of: file, suffix: ".corrupt").path) != 0 {
            Self.log.warning("could not keep the malformed dictation history (\(Self.describe(Self.posixError()), privacy: .public))")
        }
    }

    static func sibling(of file: URL, suffix: String) -> URL { URL(fileURLWithPath: file.path + suffix) }

    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// `text` cut to at most `maxBytes` of UTF-8, never inside a character (Hex's `floor_char_boundary`).
    static func truncated(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while end > text.utf8.startIndex, end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text.unicodeScalars[..<(end.samePosition(in: text.unicodeScalars) ?? text.unicodeScalars.startIndex)])
    }
}
