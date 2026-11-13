import Foundation

/// One speech-model file to fetch: where from, what to call it on disk, and what it must be once whole.
public struct ModelDownloadRequest: Sendable, Equatable {
    public var url: URL
    public var fileName: String
    public var byteCount: Int64
    /// Lowercase hex.
    public var sha256: String

    public init(url: URL, fileName: String, byteCount: Int64, sha256: String) {
        self.url = url
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// How far a download has come, for a progress bar.
public struct ModelDownloadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case downloading
        /// Every byte is in; the size and checksum are being checked before the file is installed.
        case verifying
        case installed
    }

    public var phase: Phase
    public var receivedBytes: Int64
    public var expectedBytes: Int64

    public init(phase: Phase, receivedBytes: Int64, expectedBytes: Int64) {
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    public var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

/// Why a download did not end with an installed file. A failure other than a checksum or size mismatch keeps the
/// partial file, so asking again resumes.
public enum ModelDownloadError: Error, Equatable, Sendable, LocalizedError {
    /// Stopped on request; the partial file is kept.
    case cancelled
    case alreadyDownloading
    case badStatus(Int)
    /// The server answered a ranged request with a different part of the file than asked for.
    case unexpectedRange
    case tooMuchData(expected: Int64)
    /// The finished file has the wrong length; the partial file was removed.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The finished file has the wrong checksum; the partial file was removed.
    case checksumMismatch
    case network(String)
    case disk(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "The download was stopped."
        case .alreadyDownloading: "This model is already downloading."
        case let .badStatus(status): "The server answered with status \(status)."
        case .unexpectedRange: "The server sent a different part of the file than asked for."
        case .tooMuchData: "The server sent more than the model's size."
        case let .sizeMismatch(expected, actual): "The download is \(actual) bytes, expected \(expected)."
        case .checksumMismatch: "The downloaded file is corrupted (checksum mismatch). Try again."
        case let .network(reason): "The connection failed: \(reason)"
        case let .disk(reason): "The model could not be saved: \(reason)"
        }
    }
}
