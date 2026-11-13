import CryptoKit
import Foundation

// A port of `sha256_hex` and `verify_artifact` of Hex's `src/transcription/models.rs` (MIT,
// github.com/anomalyco/hex) at v3.4.0. See THIRD_PARTY_NOTICES.md.

/// Checks a finished download against its request.
public enum ModelDownloadVerifier {
    /// Hashed a megabyte at a time: the files are gigabytes.
    private static let chunk = 1 << 20

    /// The lowercase hex SHA-256 of the file, stopping with `CancellationError` when the task is cancelled.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try autoreleasepool { try handle.read(upToCount: chunk) }
            guard let data, !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ url: URL, against request: ModelDownloadRequest) throws {
        let actual = ModelDownloadFiles.size(of: url) ?? 0
        guard actual == request.byteCount else {
            throw ModelDownloadError.sizeMismatch(expected: request.byteCount, actual: actual)
        }
        guard try sha256Hex(of: url) == request.sha256.lowercased() else { throw ModelDownloadError.checksumMismatch }
    }
}
