import XCTest
@testable import OopsCore

/// Hex's tests of model verification, receipts and removal (`src/transcription/models.rs` at v3.4.0), on the
/// five-byte fixture whose checksum is `sha256("hello")`, plus its resume decisions and receipt layout.
final class ModelDownloadHexTests: XCTestCase {
    private var directory: URL!
    private let hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oops-hex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private var fixture: ModelDownloadRequest {
        ModelDownloadRequest(
            url: URL(string: "https://example.com/fixture.gguf")!, fileName: "fixture.gguf", byteCount: 5, sha256: hello)
    }

    private var path: URL { ModelDownloadFiles.fileURL("fixture.gguf", in: directory) }

    func testArtifactVerificationChecksSizeAndChecksum() throws {
        try Data("hello".utf8).write(to: path)
        XCTAssertNoThrow(try ModelDownloadVerifier.verify(path, against: fixture))
        try Data("world".utf8).write(to: path)
        XCTAssertThrowsError(try ModelDownloadVerifier.verify(path, against: fixture))
    }

    func testArtifactVerificationNamesTheArtifactItRejects() throws {
        try Data("hello!".utf8).write(to: path)
        XCTAssertThrowsError(try ModelDownloadVerifier.verify(path, against: fixture)) { error in
            XCTAssertEqual(error as? ModelDownloadError, .sizeMismatch(expected: 5, actual: 6))
            XCTAssertTrue(error.localizedDescription.contains("expected 5"))
        }
        try Data("world".utf8).write(to: path)
        XCTAssertThrowsError(try ModelDownloadVerifier.verify(path, against: fixture)) { error in
            XCTAssertEqual(error as? ModelDownloadError, .checksumMismatch)
        }
        try Data("hello".utf8).write(to: path)
        XCTAssertNoThrow(try ModelDownloadVerifier.verify(path, against: fixture))
    }

    func testVerificationReceiptIsInvalidatedWhenTheArtifactChanges() async throws {
        try Data("hello".utf8).write(to: path)
        try ModelDownloadFiles.writeReceipt(for: fixture, in: directory)
        XCTAssertTrue(ModelDownloadFiles.isInstalled(fixture, in: directory))
        try await Task.sleep(for: .milliseconds(10))
        try Data("world".utf8).write(to: path)
        XCTAssertFalse(ModelDownloadFiles.isInstalled(fixture, in: directory))
    }

    func testRemovingAModelDeletesItsArtifacts() throws {
        let artifacts = [
            path, ModelDownloadFiles.receiptURL("fixture.gguf", in: directory),
            ModelDownloadFiles.partialURL("fixture.gguf", in: directory),
        ]
        for artifact in artifacts { try Data("model".utf8).write(to: artifact) }

        try ModelDownloadFiles.removeAll("fixture.gguf", in: directory)

        XCTAssertTrue(artifacts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertNoThrow(try ModelDownloadFiles.removeAll("fixture.gguf", in: directory))
        XCTAssertNoThrow(try ModelDownloadFiles.removeAll("fixture.gguf", in: directory.appendingPathComponent("missing")))
    }

    func testCanceledDownloadsStopBeforeIo() async throws {
        try Data("hello".utf8).write(to: path)
        let url = path
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try ModelDownloadVerifier.sha256Hex(of: url)
        }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    /// A receipt Hex wrote reads here, and one with fields Oops does not know yet (Hex's custom models add
    /// `file_id`) still reads.
    func testHexReceiptsDecodeAndToleratedExtraFields() throws {
        let hex = Data(#"{"bytes":1241056,"sha256":"0d87","modified_ns":1793707506062659920}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ModelDownloadReceipt.self, from: hex),
            ModelDownloadReceipt(bytes: 1_241_056, sha256: "0d87", modifiedNs: 1_793_707_506_062_659_920))
        let later = Data(#"{"bytes":5,"sha256":"x","modified_ns":1,"file_id":12345}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ModelDownloadReceipt.self, from: later).bytes, 5)
        let written = try JSONEncoder().encode(ModelDownloadReceipt(bytes: 5, sha256: "x", modifiedNs: 1))
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("\"modified_ns\":1"))
    }

    func testResumeDecisionsFollowThePartialFileAndTheServersAnswer() {
        XCTAssertEqual(ModelDownloadPlan.start(partialBytes: nil, expected: 100), .fetch(from: 0))
        XCTAssertEqual(ModelDownloadPlan.start(partialBytes: 40, expected: 100), .fetch(from: 40))
        XCTAssertEqual(ModelDownloadPlan.start(partialBytes: 100, expected: 100), .verifyPartial)
        XCTAssertEqual(ModelDownloadPlan.start(partialBytes: 101, expected: 100), .discardPartial)
        XCTAssertNil(ModelDownloadPlan.rangeHeader(from: 0))
        XCTAssertEqual(ModelDownloadPlan.rangeHeader(from: 40), "bytes=40-")

        XCTAssertEqual(ModelDownloadPlan.reply(status: 206, contentRange: "bytes 40-99/100", offset: 40), .append)
        XCTAssertEqual(
            ModelDownloadPlan.reply(status: 206, contentRange: "bytes 0-99/100", offset: 40), .failure(.unexpectedRange))
        XCTAssertEqual(ModelDownloadPlan.reply(status: 206, contentRange: nil, offset: 40), .failure(.unexpectedRange))
        XCTAssertEqual(ModelDownloadPlan.reply(status: 200, contentRange: nil, offset: 40), .restart)
        XCTAssertEqual(ModelDownloadPlan.reply(status: 416, contentRange: nil, offset: 40), .discardPartial)
        XCTAssertEqual(ModelDownloadPlan.reply(status: 416, contentRange: nil, offset: 0), .failure(.badStatus(416)))
        XCTAssertEqual(ModelDownloadPlan.reply(status: 503, contentRange: nil, offset: 0), .failure(.badStatus(503)))
    }
}
