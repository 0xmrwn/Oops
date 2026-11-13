import XCTest
@testable import OopsCore

/// Hex's vocabulary entry tests (`src/dictation/vocabulary.rs` at 1b82cc0), each under its upstream name in the Swift
/// style. Not ported: the tests of the process-wide list, the focused mode's terms and settings.json reading, which
/// Oops keeps elsewhere.
final class VocabularyEntryTests: XCTestCase {
    func entry(_ term: String, _ soundsLike: [String] = []) -> VocabularyEntry {
        VocabularyEntry(term: term, soundsLike: soundsLike)
    }

    func testPlainTermsLoadAsStringsAndEntriesKeepTheirObjectForm() throws {
        struct File: Codable, Equatable { var vocabulary: [VocabularyEntry] }
        let json = Data(#"{"vocabulary": ["Rune", {"term": "OpenCode", "sounds_like": ["open code"]}, {"term": "Kaffar"}]}"#.utf8)
        let file = try JSONDecoder().decode(File.self, from: json)
        XCTAssertEqual(file.vocabulary, [entry("Rune"), entry("OpenCode", ["open code"]), entry("Kaffar")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(entry("Rune")), as: UTF8.self), #"{"term":"Rune"}"#)
        XCTAssertEqual(
            String(decoding: try encoder.encode(entry("OpenCode", ["open code"])), as: UTF8.self),
            #"{"sounds_like":["open code"],"term":"OpenCode"}"#
        )
        XCTAssertEqual(try JSONDecoder().decode(File.self, from: encoder.encode(file)), file)
    }

    func testAModesTermsComeFirstAndEachTermOnce() {
        let own = [entry("useEffect"), entry("Rune", ["rooney"])]
        let shared = [entry("rune"), entry("OpenCode")]
        XCTAssertEqual(Vocabulary.merged(own, shared), [entry("useEffect"), entry("Rune", ["rooney"]), entry("OpenCode")])
        XCTAssertEqual(Vocabulary.merged([], shared), shared)
    }

    func testAddingDedupesByCaseAndMergesSpellings() throws {
        var list: [VocabularyEntry] = []
        XCTAssertTrue(try Vocabulary.add(&list, term: "  Cappuccino ", soundsLike: ["capuchin", ""]))
        XCTAssertEqual(list, [entry("Cappuccino", ["capuchin"])])
        XCTAssertFalse(try Vocabulary.add(&list, term: "cappuccino", soundsLike: ["Capuchin"]))
        XCTAssertTrue(try Vocabulary.add(&list, term: "CAPPUCCINO", soundsLike: ["cap a chino"]))
        XCTAssertEqual(list, [entry("Cappuccino", ["capuchin", "cap a chino"])])
        // A spelling identical to its term adds nothing.
        XCTAssertFalse(try Vocabulary.add(&list, term: "Cappuccino", soundsLike: ["cappuccino"]))
        XCTAssertThrowsError(try Vocabulary.add(&list, term: "   ")) { XCTAssertEqual($0 as? VocabularyError, .emptyTerm) }
        let long = String(repeating: "x", count: 65)
        XCTAssertThrowsError(try Vocabulary.add(&list, term: long)) { XCTAssertEqual($0 as? VocabularyError, .tooLong(long)) }
        XCTAssertEqual(list.count, 1)
    }

    func testTheListAndEachEntryHaveLimits() throws {
        var list: [VocabularyEntry] = []
        for index in 0 ..< Vocabulary.maxEntries { try Vocabulary.add(&list, term: "term \(index)") }
        XCTAssertThrowsError(try Vocabulary.add(&list, term: "one more")) { XCTAssertEqual($0 as? VocabularyError, .tooManyTerms) }
        // An existing term still takes spellings in a full list.
        XCTAssertTrue(try Vocabulary.add(&list, term: "term 0", soundsLike: ["zero"]))
        let spellings = (0 ..< 17).map { "spelling \($0)" }
        XCTAssertThrowsError(try Vocabulary.add(&list, term: "term 1", soundsLike: spellings)) {
            XCTAssertEqual($0 as? VocabularyError, .tooManySoundsLike)
        }
        XCTAssertFalse((VocabularyError.tooManyTerms.errorDescription ?? "").isEmpty)
    }

    func testClampedAddsKeepTheTermAndTheSpellingsThatFit() {
        let spellings = (0 ..< 20).map { "spelling \($0)" }
        var list: [VocabularyEntry] = []
        let withLong = Array(spellings[..<2]) + [String(repeating: "y", count: 65)]
        XCTAssertTrue(Vocabulary.addClamped(&list, term: "Cappuccino", soundsLike: withLong))
        XCTAssertEqual(list, [entry("Cappuccino", ["spelling 0", "spelling 1"])])
        XCTAssertTrue(Vocabulary.addClamped(&list, term: "cappuccino", soundsLike: spellings))
        XCTAssertEqual(list[0].soundsLike, Array(spellings[..<Vocabulary.maxSoundsLike]))

        XCTAssertTrue(Vocabulary.addClamped(&list, term: String(repeating: "x", count: 70), soundsLike: ["ex"]))
        XCTAssertEqual(list[1], entry(String(repeating: "x", count: Vocabulary.maxTermCharacters), ["ex"]))
        XCTAssertFalse(Vocabulary.addClamped(&list, term: "Rune", soundsLike: ["roon"]))
        XCTAssertFalse(Vocabulary.addClamped(&list, term: "  "))
        XCTAssertEqual(list.count, 3)
    }

    func testRemovingIgnoresCase() {
        var list = [entry("OpenCode"), entry("Rune")]
        XCTAssertTrue(Vocabulary.remove(&list, term: "opencode"))
        XCTAssertFalse(Vocabulary.remove(&list, term: "opencode"))
        XCTAssertEqual(list, [entry("Rune")])
        XCTAssertTrue(Vocabulary.contains(list, term: " RUNE "))
    }

    func testHintsFoldIntoTheListWithoutDuplicates() {
        var list = [entry("OpenCode", ["open code"])]
        XCTAssertTrue(Vocabulary.foldHints(&list, "opencode, Effect;Rune\n  ,Effect"))
        XCTAssertEqual(list, [entry("OpenCode", ["open code"]), entry("Effect"), entry("Rune")])
        XCTAssertFalse(Vocabulary.foldHints(&list, "Rune, effect"))
        XCTAssertFalse(Vocabulary.foldHints(&list, "  "))
    }

    func testSoundsLikeSplitsOnCommas() {
        XCTAssertEqual(Vocabulary.parseSoundsLike(" capuchin,, cap  a chino ,"), ["capuchin", "cap a chino"])
        XCTAssertTrue(Vocabulary.parseSoundsLike(" , ").isEmpty)
    }
}
