import Foundation

// A port of the model files of Hex (MIT, github.com/anomalyco/hex): the `.partial` file of `src/net/download.rs`
// and the `.verified.json` receipt of `src/transcription/models.rs` (`VerificationReceipt`,
// `artifact_receipt_matches`), at v3.4.0. Same layout and the same receipt keys, so Hex's models folder reads here.
// See THIRD_PARTY_NOTICES.md.

/// What a verified model leaves beside it. Installed means the file is there and this receipt agrees with it.
public struct ModelDownloadReceipt: Codable, Equatable, Sendable {
    public var bytes: Int64
    public var sha256: String
    /// The installed file's modification time. A file changed after its check no longer matches.
    public var modifiedNs: UInt64

    public init(bytes: Int64, sha256: String, modifiedNs: UInt64) {
        self.bytes = bytes
        self.sha256 = sha256
        self.modifiedNs = modifiedNs
    }

    // Hex's key names. Unknown keys (Hex's custom-model receipts add `file_id`) are ignored when decoding.
    private enum CodingKeys: String, CodingKey {
        case bytes, sha256
        case modifiedNs = "modified_ns"
    }
}

/// Where a model's files live and whether it counts as installed.
public enum ModelDownloadFiles {
    public static func fileURL(_ fileName: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    public static func partialURL(_ fileName: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName + ".partial")
    }

    public static func receiptURL(_ fileName: String, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName + ".verified.json")
    }

    /// The file's size and modification time in nanoseconds, from `stat` so the receipt compares exactly.
    public static func fingerprint(_ url: URL) -> (bytes: Int64, modifiedNs: UInt64)? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return (Int64(info.st_size), UInt64(max(0, nanoseconds)))
    }

    public static func size(of url: URL) -> Int64? { fingerprint(url)?.bytes }

    public static func readReceipt(_ fileName: String, in directory: URL) -> ModelDownloadReceipt? {
        guard let data = try? Data(contentsOf: receiptURL(fileName, in: directory)) else { return nil }
        return try? JSONDecoder().decode(ModelDownloadReceipt.self, from: data)
    }

    /// Records that the file in place was verified. Written whole or not at all, so a crash leaves no half receipt.
    public static func writeReceipt(for request: ModelDownloadRequest, in directory: URL) throws {
        guard let fingerprint = fingerprint(fileURL(request.fileName, in: directory)) else {
            throw ModelDownloadError.disk("\(request.fileName) is missing")
        }
        let receipt = ModelDownloadReceipt(
            bytes: request.byteCount, sha256: request.sha256, modifiedNs: fingerprint.modifiedNs)
        try JSONEncoder().encode(receipt).write(to: receiptURL(request.fileName, in: directory), options: .atomic)
    }

    /// The file is there at the expected size, and its receipt names the expected checksum and this very file.
    public static func isInstalled(_ request: ModelDownloadRequest, in directory: URL) -> Bool {
        guard let fingerprint = fingerprint(fileURL(request.fileName, in: directory)),
              let receipt = readReceipt(request.fileName, in: directory)
        else { return false }
        return fingerprint.bytes == request.byteCount
            && receipt.bytes == request.byteCount
            && receipt.sha256 == request.sha256
            && receipt.modifiedNs == fingerprint.modifiedNs
    }

    /// Removes the file, its partial and its receipt; what is not there is skipped.
    public static func removeAll(_ fileName: String, in directory: URL) throws {
        for url in [fileURL(fileName, in: directory), partialURL(fileName, in: directory),
                    receiptURL(fileName, in: directory)] {
            do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
        }
    }
}
