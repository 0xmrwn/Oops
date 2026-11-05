import XCTest
@testable import OopsCore

final class DebugLogStoreTests: XCTestCase {
    private var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent("oops-log-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func attempt(_ date: String, source: String) -> DebugEntry {
        var attempt = DebugAttempt(date: ISO8601DateFormatter().date(from: date)!, outcome: .fixed)
        attempt.source = source; attempt.corrected = source
        return .attempt(attempt)
    }

    func testEntriesRoundTripAcrossMonthsWithRevertLabels() throws {
        let store = DebugLogStore(directory: directory)
        let first = attempt("2026-09-15T12:00:00Z", source: "ths")
        store.append(first)
        guard case .attempt(let logged) = first else { return XCTFail("expected an attempt") }
        store.append(.revert(.init(attempt: logged.id, date: ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")!)))
        XCTAssertEqual(store.entries(), [first, .revert(.init(attempt: logged.id, date: ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")!))])
        XCTAssertEqual(store.files().count, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.files()[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testGrowingMonthPrunesOlderOnesButKeepsItself() {
        let store = DebugLogStore(directory: directory, capacity: 1_024)
        store.append(attempt("2026-09-15T12:00:00Z", source: String(repeating: "a", count: 300)))
        for _ in 0..<2 { store.append(attempt("2026-10-15T12:00:00Z", source: String(repeating: "b", count: 300))) }
        store.flush()
        XCTAssertEqual(store.files().map(\.lastPathComponent), ["corrections-2026-10.jsonl"])
        for _ in 0..<3 { store.append(attempt("2026-10-16T12:00:00Z", source: String(repeating: "c", count: 300))) }
        store.flush()
        XCTAssertEqual(store.entries().count, 5, "the current month is never pruned")
    }
}
