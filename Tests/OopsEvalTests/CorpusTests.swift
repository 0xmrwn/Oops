import XCTest
import OopsCore
@testable import OopsEval

final class CorpusTests: XCTestCase {
    private func fixed(_ source: String, _ corrected: String) -> DebugAttempt {
        var attempt = DebugAttempt(outcome: .fixed)
        attempt.source = source; attempt.corrected = corrected
        attempt.app = .init(bundleID: "com.example.chat", name: "Chat", version: nil)
        return attempt
    }

    func testRevertRejectsUnlessTheFixWasPutBackAfter() {
        let reverted = fixed("ths", "this"), kept = fixed("smal", "small"), again = fixed("teh", "the")
        let cases = Corpus.export([
            .attempt(reverted), .attempt(kept), .attempt(again),
            .revert(.init(attempt: reverted.id)),
            .revert(.init(attempt: kept.id)), .reapply(.init(attempt: kept.id)),
            .revert(.init(attempt: again.id)), .reapply(.init(attempt: again.id)), .revert(.init(attempt: again.id)),
        ], options: .init())
        let labels = Dictionary(uniqueKeysWithValues: cases.map { ($0.input, $0.label) })
        XCTAssertEqual(labels, ["ths": .rejected, "smal": .accepted, "teh": .rejected])
    }
}
