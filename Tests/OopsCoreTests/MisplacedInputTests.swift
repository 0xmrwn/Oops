import XCTest
@testable import OopsCore

final class MisplacedInputTests: XCTestCase {
    func testRepeatedSingleLetterDoesNotStallUndo() {
        let draft = String(repeating: "a", count: 24_000) + "x"
        let current = String(repeating: "a", count: 24_000) + "y"
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertFalse(TextEdits.misplaced("a", in: current, over: draft))
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    }

    func testMatchesLiteralSpliceDefinition() {
        func strings(_ alphabet: [String], through length: Int) -> [String] {
            var all = [""], level = [""]
            for _ in 0..<length {
                level = level.flatMap { prefix in alphabet.map { prefix + $0 } }
                all += level
            }
            return all
        }
        func reference(_ pasted: String, _ current: String, _ draft: String) -> Bool {
            let c = Array(current.utf16), d = Array(draft.utf16), p = Array(pasted.utf16)
            guard !p.isEmpty, c.count >= p.count, c != d else { return false }
            for start in 0...(c.count - p.count) where Array(c[start..<(start + p.count)]) == p {
                let head = c[..<start], tail = c[(start + p.count)...]
                if head.count + tail.count <= d.count, d.starts(with: head), d.reversed().starts(with: tail.reversed()) { return true }
            }
            return false
        }
        for (alphabet, length) in [(["a", "b"], 4), (["ا", "أ", "🧪"], 2), (["é", "e\u{301}"], 2)] {
            let drafts = strings(alphabet, through: length), pastes = strings(alphabet, through: 2)
            for draft in drafts {
                for current in drafts {
                    for pasted in pastes {
                        guard TextEdits.misplaced(pasted, in: current, over: draft) == reference(pasted, current, draft) else {
                            XCTFail("Splice mismatch: \(draft.debugDescription), \(current.debugDescription), \(pasted.debugDescription)")
                            return
                        }
                    }
                }
            }
        }
    }
}
