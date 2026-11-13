import Foundation

// A port of the resume decisions of Hex's `src/net/download.rs` and `download_artifact` (MIT,
// github.com/anomalyco/hex) at v3.4.0. See THIRD_PARTY_NOTICES.md.

/// What to do with the partial file before asking the server for more, and how to read its answer.
public enum ModelDownloadPlan {
    public enum Start: Equatable, Sendable {
        /// Fetch from this byte on (0 for a fresh file).
        case fetch(from: Int64)
        /// The partial file is the whole length: check it instead of fetching.
        case verifyPartial
        /// The partial file is longer than the model, so it cannot be a prefix of it.
        case discardPartial
    }

    public enum Reply: Equatable, Sendable {
        /// 206 starting where asked: append.
        case append
        /// 200: the server ignored the range and sends the whole file, so start the file over.
        case restart
        /// 416: the range is not one the server has, so the partial file is no use.
        case discardPartial
        case failure(ModelDownloadError)
    }

    public static func start(partialBytes: Int64?, expected: Int64) -> Start {
        guard let partialBytes, partialBytes > 0 else { return .fetch(from: 0) }
        if partialBytes > expected { return .discardPartial }
        if partialBytes == expected { return .verifyPartial }
        return .fetch(from: partialBytes)
    }

    /// `nil` for a fetch from the start: a plain request, as a server may not take a range at 0.
    public static func rangeHeader(from offset: Int64) -> String? {
        offset > 0 ? "bytes=\(offset)-" : nil
    }

    public static func reply(status: Int, contentRange: String?, offset: Int64) -> Reply {
        switch status {
        case 206:
            guard let start = rangeStart(contentRange), start == offset else {
                return .failure(.unexpectedRange)
            }
            return .append
        case 200: return .restart
        case 416 where offset > 0: return .discardPartial
        default: return .failure(.badStatus(status))
        }
    }

    /// The first byte of `Content-Range: bytes 100-199/200`.
    static func rangeStart(_ contentRange: String?) -> Int64? {
        guard let contentRange, contentRange.hasPrefix("bytes ") else { return nil }
        let span = contentRange.dropFirst("bytes ".count)
        guard let dash = span.firstIndex(of: "-") else { return nil }
        return Int64(span[..<dash])
    }
}
