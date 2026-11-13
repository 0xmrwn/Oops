import XCTest
@testable import OopsCore

/// The store against a real local HTTP server: a complete download, a drop and resume, a bad checksum, a cancel,
/// a delete, and servers that ignore or refuse `Range`.
final class ModelDownloadStoreTests: XCTestCase, ModelDownloadTesting {
    var directory: URL!
    var server: RangeServer!
    var base: URL!

    override func setUp() async throws { try await startServer() }
    override func tearDown() { stopServer() }

    func testCompleteDownloadInstallsTheFileAndWritesItsReceipt() async throws {
        let store = store()
        let request = request()
        let installedBefore = await store.isInstalled(request)
        XCTAssertFalse(installedBefore)

        let result = await drain(store.download(request))

        XCTAssertNil(result.error)
        XCTAssertEqual(result.progress.last?.phase, .installed)
        XCTAssertEqual(result.progress.last?.fraction, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL), server.body)
        XCTAssertFalse(exists(partialURL))
        let receipt = try XCTUnwrap(ModelDownloadFiles.readReceipt(fileName, in: directory))
        XCTAssertEqual(receipt.bytes, request.byteCount)
        XCTAssertEqual(receipt.sha256, request.sha256)
        let installed = await store.isInstalled(request)
        let url = await store.installedFileURL(for: request)
        XCTAssertTrue(installed)
        XCTAssertEqual(url, fileURL)
        XCTAssertEqual(server.ranges, [nil], "a fresh download asks for the whole file")
    }

    func testProgressNeverGoesBackwardsWhileDownloading() async {
        let result = await drain(store().download(request()))
        let received = result.progress.filter { $0.phase == .downloading }.map(\.receivedBytes)
        XCTAssertEqual(received, received.sorted())
        XCTAssertTrue(result.progress.allSatisfy { $0.expectedBytes == Int64(server.body.count) })
    }

    func testInterruptedDownloadResumesFromThePartialFile() async throws {
        let store = store(attempts: 1)
        server.script([.init(dropAfter: 100_000)])
        let first = await drain(store.download(request()))

        guard case .network = first.error else { return XCTFail("expected a network error, got \(String(describing: first.error))") }
        let kept = try XCTUnwrap(ModelDownloadFiles.size(of: partialURL))
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, Int64(server.body.count))
        XCTAssertFalse(exists(fileURL))
        let installedAfterDrop = await store.isInstalled(request())
        XCTAssertFalse(installedAfterDrop)

        let second = await drain(store.download(request()))

        XCTAssertNil(second.error)
        XCTAssertEqual(server.ranges, [nil, "bytes=\(kept)-"])
        XCTAssertEqual(sha256(try Data(contentsOf: fileURL)), request().sha256)
        let installedAfterResume = await store.isInstalled(request())
        XCTAssertTrue(installedAfterResume)
    }

    func testADroppedConnectionIsRetriedWithinOneDownload() async {
        server.script([.init(dropAfter: 50000)])
        let result = await drain(store(attempts: 3).download(request()))
        XCTAssertNil(result.error)
        let ranges = server.ranges
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.first, .some(nil))
        XCTAssertTrue(ranges.last??.hasPrefix("bytes=") == true, "the retry resumes: \(ranges)")
    }

    func testChecksumMismatchRejectsTheFileAndRemovesThePartial() async {
        let store = store()
        let wrong = request(checksum: sha256(Data("something else".utf8)))
        let result = await drain(store.download(wrong))

        XCTAssertEqual(result.error, .checksumMismatch)
        XCTAssertFalse(exists(partialURL))
        XCTAssertFalse(exists(fileURL))
        XCTAssertFalse(exists(receiptURL))
        let installed = await store.isInstalled(wrong)
        XCTAssertFalse(installed)
    }

    func testCancelKeepsThePartialFileAndALaterDownloadResumes() async throws {
        let store = store()
        server.script([.init(stallAfter: 80000)])
        let stream = store.download(request())
        let running = Task { await drain(stream) }
        await eventually { ModelDownloadFiles.size(of: partialURL) == 80000 }

        await store.cancel(fileName: fileName)
        let cancelled = await running.value

        XCTAssertEqual(cancelled.error, .cancelled)
        XCTAssertEqual(ModelDownloadFiles.size(of: partialURL), 80000)
        let installedAfterCancel = await store.isInstalled(request())
        XCTAssertFalse(installedAfterCancel)

        let resumed = await drain(store.download(request()))

        XCTAssertNil(resumed.error)
        XCTAssertEqual(server.ranges, [nil, "bytes=80000-"])
        XCTAssertEqual(try Data(contentsOf: fileURL), server.body)
        let installed = await store.isInstalled(request())
        XCTAssertTrue(installed)
    }

    func testDroppingTheStreamStopsTheTransferButKeepsThePartial() async throws {
        let store = store()
        server.script([.init(stallAfter: 60000)])
        let stream = store.download(request())
        let running = Task {
            for try await _ in stream {}
        }
        await eventually { ModelDownloadFiles.size(of: partialURL) == 60000 }
        running.cancel()
        _ = await running.result

        // The transfer ends on its own time after the consumer lets go; until then the file counts as busy.
        var again = await drain(store.download(request()))
        for _ in 0 ..< 500 where again.error == .alreadyDownloading {
            try await Task.sleep(for: .milliseconds(10))
            again = await drain(store.download(request()))
        }
        XCTAssertNil(again.error)
        XCTAssertEqual(server.ranges, [nil, "bytes=60000-"])
    }

    func testASecondDownloadOfTheSameFileWhileOneRunsIsRefused() async {
        let store = store()
        server.script([.init(stallAfter: 1000)])
        let stream = store.download(request())
        let running = Task { await drain(stream) }
        await eventually { ModelDownloadFiles.size(of: partialURL) == 1000 }

        let second = await drain(store.download(request()))
        XCTAssertEqual(second.error, .alreadyDownloading)

        await store.cancel(fileName: fileName)
        _ = await running.value
    }

    func testDeleteRemovesTheFileItsPartialAndItsReceipt() async throws {
        let store = store()
        _ = await drain(store.download(request()))
        try Data("left over".utf8).write(to: partialURL)
        let installedBefore = await store.isInstalled(request())
        XCTAssertTrue(installedBefore)

        try await store.delete(fileName: fileName)

        XCTAssertFalse(exists(fileURL))
        XCTAssertFalse(exists(partialURL))
        XCTAssertFalse(exists(receiptURL))
        let installedAfter = await store.isInstalled(request())
        let url = await store.installedFileURL(for: request())
        XCTAssertFalse(installedAfter)
        XCTAssertNil(url)
        try await store.delete(fileName: fileName)
    }

    func testAServerThatIgnoresRangeRestartsTheFileCleanly() async throws {
        let store = store(attempts: 1)
        server.script([.init(dropAfter: 100_000), .init(honorsRange: false)])
        _ = await drain(store.download(request()))
        let kept = try XCTUnwrap(ModelDownloadFiles.size(of: partialURL))

        let result = await drain(store.download(request()))

        XCTAssertNil(result.error)
        XCTAssertEqual(server.ranges, [nil, "bytes=\(kept)-"])
        XCTAssertEqual(try Data(contentsOf: fileURL), server.body, "the old prefix was not kept in front of the whole file")
    }

    func testARefusedRangeDiscardsThePartialAndStartsOver() async throws {
        server.script([.init(rejectsRange: true)])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1000).write(to: partialURL)

        let result = await drain(store().download(request()))

        XCTAssertNil(result.error)
        XCTAssertEqual(server.ranges, ["bytes=1000-", nil])
        XCTAssertEqual(try Data(contentsOf: fileURL), server.body)
    }

    func testAPartialFileLongerThanTheModelIsDiscarded() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: server.body.count + 1).write(to: partialURL)

        let result = await drain(store().download(request()))

        XCTAssertNil(result.error)
        XCTAssertEqual(server.ranges, [nil])
    }

    func testAWholePartialFileIsVerifiedWithoutAskingTheServer() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try server.body.write(to: partialURL)

        let result = await drain(store().download(request()))

        XCTAssertNil(result.error)
        XCTAssertTrue(server.ranges.isEmpty)
        XCTAssertFalse(exists(partialURL))
        XCTAssertTrue(ModelDownloadFiles.isInstalled(request(), in: directory))
    }

    func testAFileWithoutAReceiptIsNotInstalledUntilItIsChecked() async throws {
        let store = store()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try server.body.write(to: fileURL)
        let before = await store.isInstalled(request())
        XCTAssertFalse(before, "a file alone is not installed")

        let result = await drain(store.download(request()))

        XCTAssertNil(result.error)
        XCTAssertTrue(server.ranges.isEmpty, "a whole file that checks out is adopted, not fetched again")
        let after = await store.isInstalled(request())
        XCTAssertTrue(after)
    }

    func testAnInstalledModelIsNotFetchedAgain() async {
        let store = store()
        _ = await drain(store.download(request()))
        let result = await drain(store.download(request()))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.progress.last?.phase, .installed)
        XCTAssertEqual(server.ranges.count, 1)
    }

    func testAServerSendingMoreThanTheModelsSizeIsRejected() async {
        var tooSmall = request()
        tooSmall.byteCount -= 10

        let result = await drain(store().download(tooSmall))

        XCTAssertEqual(result.error, .tooMuchData(expected: tooSmall.byteCount))
        XCTAssertFalse(ModelDownloadFiles.isInstalled(tooSmall, in: directory))
    }
}
