import XCTest
@testable import OopsCore

/// Reconcile inside a draft, and the per-span edits that apply a correction.
final class ReconcileTests: XCTestCase {
    func testSelectionCannotRewriteItsEnclosingMention() throws {
        let value = "ping @writr about teh docs"
        let selection = (value as NSString).range(of: "writr about teh")
        let transaction = try TextTransaction(value: value, selection: selection)
        let raw = #"{"text":"writer about the"}"#
        let result = try CorrectionPolicy.reconcile(raw, original: transaction.source, prefix: transaction.prefix, suffix: transaction.suffix)
        XCTAssertEqual(result.text, "writr about the")
        XCTAssertEqual(result.dropped.map(\.rule), [.protectedSpan])
    }

    func testChangesSafeApartButNotTogetherAreRefused() {
        // Each backtick alone opens nothing; together they would make a code span.
        let result = CorrectionPolicy.reconcile(answer: "a `b c` d", original: "a b c d")
        XCTAssertEqual(result.text, "a `b c d")
        XCTAssertEqual(result.dropped.count, 1)
    }

    func testEmbeddedObjectsAreNeverAdded() {
        let result = CorrectionPolicy.reconcile(answer: "the \u{FFFC} end", original: "teh  end")
        XCTAssertFalse(result.text.contains("\u{FFFC}"))
    }

    func testEditsLeaveTheTextBetweenFixesAlone() {
        let before = "teh @alice smal `x` thng", after = "the @alice small `x` thing"
        let edits = TextEdits.between(before, after)
        XCTAssertEqual(edits.map(\.original), ["teh", "smal", "thng"])
        XCTAssertEqual(edits.map(\.replacement), ["the", "small", "thing"])
        XCTAssertEqual(CorrectionPolicy.applying(edits, to: before), after)
    }

    func testEditsAreTrimmedToWholeCharacters() {
        let before = "café 👨‍👩‍👧 ths", after = "café 👨‍👩‍👧 this"
        let edits = TextEdits.between(before, after)
        XCTAssertEqual(edits, [TextChange(location: (before as NSString).length - 3, original: "ths", replacement: "this")])
        XCTAssertEqual(CorrectionPolicy.applying(edits, to: before), after)
    }

    func testEveryPasteReplacesText() {
        // An insertion pasted at a bare caret can land wherever the editor left its caret, and leaves
        // nothing to check the selection against.
        for (before, after) in [("a smal cat", "a small cat"), ("a b", "a, b"), ("x. y", "x. ! y"), ("teh \u{FFFC}.", "the \u{FFFC}!."),
                                ("ok\u{FFFC} .", "ok\u{FFFC}  .")] {
            let edits = TextEdits.between(before, after)
            XCTAssertFalse(edits.contains { $0.original.isEmpty || $0.replacement.isEmpty }, before)
            XCTAssertFalse(edits.contains { $0.original.contains("\u{FFFC}") }, before)
            XCTAssertEqual(CorrectionPolicy.applying(edits, to: before), after, before)
        }
    }

    func testAnIgnoredPasteIsNeverTakenForAMisplacedOne() {
        // The replacement already occurs in the unchanged draft: no proof the editor pasted anywhere.
        XCTAssertFalse(TextEdits.misplaced("the", in: "the teh docs", over: "the teh docs"))
        XCTAssertTrue(TextEdits.misplaced("the", in: "thethe teh docs", over: "the teh docs"))
    }

    func testAPasteAtTheWrongSelectionIsRecognised() {
        let draft = "keep this smal part"
        XCTAssertTrue(TextEdits.misplaced("small", in: "smallkeep this smal part", over: draft))
        XCTAssertTrue(TextEdits.misplaced("small", in: "keep small", over: draft))
        XCTAssertFalse(TextEdits.misplaced("small", in: draft, over: draft))
        XCTAssertFalse(TextEdits.misplaced("small", in: "keep this smal part, and more", over: draft))
        XCTAssertFalse(TextEdits.misplaced("small", in: "kept this smallish part", over: draft))
    }

    func testAnUndoCountsOnlyWhenItLandsExactlyBeforeThePaste() {
        let draft = "keep this smal part", misplaced = "smallkeep this smal part"
        XCTAssertEqual(TextEdits.undo(draft, before: draft, misplaced: misplaced), .restored)
        XCTAssertEqual(TextEdits.undo(misplaced, before: draft, misplaced: misplaced), .pending)
        // Grouped with the person's last typing, the undo went past the paste: that must be redone.
        XCTAssertEqual(TextEdits.undo("keep this smal", before: draft, misplaced: misplaced), .overshot)
        XCTAssertEqual(TextEdits.undo("", before: draft, misplaced: misplaced), .overshot)
    }

    func testTrailingLeadingAndAdjacentAtomsAreSpelled() {
        XCTAssertEqual(TextEdits.atomSpelling(value: "teh 🎉", markers: "teh \u{FFFC}"), 2)
        XCTAssertEqual(TextEdits.atomSpelling(value: "teh ", markers: "teh \u{FFFC}"), 0)
        XCTAssertEqual(TextEdits.atomSpelling(value: "🎉 teh", markers: "\u{FFFC} teh"), 2)
        XCTAssertEqual(TextEdits.atomSpelling(value: "a 🎉🎉 b", markers: "a \u{FFFC}\u{FFFC} b"), 4)
        XCTAssertEqual(TextEdits.atomSpelling(value: "a 🎉🎉", markers: "a \u{FFFC}\u{FFFC}"), 4)
        XCTAssertNil(TextEdits.atomSpelling(value: "teh 🎉 extra words that run on", markers: "teh \u{FFFC}"))
        XCTAssertNil(TextEdits.atomSpelling(value: "tah 🎉", markers: "teh \u{FFFC}"))
    }

    func testAValueSpellsTheAtomsItsMarkersCount() {
        // Chromium spells an image as its alt text; WebKit and Gecko leave it out.
        XCTAssertEqual(TextEdits.atomSpelling(value: "teh 🎉 smal", markers: "teh \u{FFFC} smal"), 2)
        XCTAssertEqual(TextEdits.atomSpelling(value: "teh  smal", markers: "teh \u{FFFC} smal"), 0)
        XCTAssertEqual(TextEdits.atomSpelling(value: "a @Alice Martin b \u{FEFF}", markers: "a \u{FFFC} b \u{FEFF}"), 13)
        // A text control is one atom in its document's markers: not the same text.
        XCTAssertNil(TextEdits.atomSpelling(value: "keep thsi part", markers: "\u{FFFC}"))
        XCTAssertNil(TextEdits.atomSpelling(value: "teh smal", markers: "teh smal"))
        XCTAssertNil(TextEdits.atomSpelling(value: "teh 🎉 small", markers: "teh \u{FFFC} smal"))
    }

    func testAnEditorChangingTextBesideThePasteIsRecognised() {
        let expected = "fix teh @Alice Martin part, it is a small change"
        let pasted = (expected as NSString).range(of: "small")
        XCTAssertTrue(TextEdits.changedBeside(pasted, current: "fix teh @Alice Martinpart, it is a small change", expected: expected))
        XCTAssertFalse(TextEdits.changedBeside(pasted, current: "fix teh @Alice Martin part, it is a smal change", expected: expected))
        XCTAssertFalse(TextEdits.changedBeside(pasted, current: expected, expected: expected))
    }

    func testACorrectionMovesOntoADraftReportedAgainDifferentlyAwayFromItsChanges() {
        let before = "تحديت خطة @Alice Martin الأسبوع", after = "تحديث خطة @Alice Martin الأسبوع"
        XCTAssertEqual(TextEdits.rebase(before: before, after: after, onto: "تحديت خطة Alice Martin@ الأسبوع"),
                       "تحديث خطة Alice Martin@ الأسبوع")
        XCTAssertNil(TextEdits.rebase(before: before, after: after, onto: "تحديد خطة @Alice Martin الأسبوع"))
        XCTAssertNil(TextEdits.rebase(before: before, after: after, onto: before + " "))
        XCTAssertEqual(TextEdits.rebase(before: "", after: "", onto: ""), "")
    }

    func testWordsInUnspacedScriptsWidenOnlySoFar() {
        let line = String(repeating: "日本語", count: 20)
        let edits = TextEdits.between(line + "の", line + "が")
        XCTAssertEqual(edits.count, 1)
        XCTAssertLessThanOrEqual(edits[0].original.utf16.count, 26)
    }

    func testAttachmentsAreProtected() {
        // A model that drops the attachment loses that change, not the attachment.
        let result = CorrectionPolicy.reconcile(answer: "the small", original: "teh \u{FFFC} smal")
        XCTAssertEqual(result.text, "the \u{FFFC} smal")
        XCTAssertEqual(CorrectionPolicy.reconcile(answer: "the \u{FFFC} small", original: "teh \u{FFFC} smal").text, "the \u{FFFC} small")
        XCTAssertFalse(CorrectionPolicy.hasProse("\u{FFFC} \u{FFFC}"))
    }

    func testDeletionsStillPasteSomething() {
        for (before, after) in [("line twoo", "line two"), ("this is", "ths is"), ("xthe cat", "the cat"), ("a 👍👍 b", "a 👍 b")] {
            let edits = TextEdits.between(before, after)
            XCTAssertFalse(edits.contains { $0.replacement.isEmpty }, before)
            XCTAssertEqual(CorrectionPolicy.applying(edits, to: before), after, before)
        }
    }

    func testManyEditsJoinAcrossPlainGapsOnly() {
        let words = (0..<30).map { "w\($0)x" }
        let before = words.joined(separator: " ") + "\n@bob " + words.joined(separator: " ")
        let after = words.map { $0.replacingOccurrences(of: "x", with: "y") }.joined(separator: " ") + "\n@bob "
            + words.map { $0.replacingOccurrences(of: "x", with: "y") }.joined(separator: " ")
        let edits = TextEdits.between(before, after, limit: 10)
        XCTAssertLessThanOrEqual(edits.count, 10)
        XCTAssertFalse(edits.contains { $0.original.contains("\n") || $0.original.contains("@bob") })
        XCTAssertEqual(CorrectionPolicy.applying(edits, to: before), after)
    }

    func testDiffKeysMatchTypographyOnly() {
        let diff = WordDiff(before: "it's 2-3", after: "it’s 2–4", key: CorrectionPolicy.fold)
        XCTAssertEqual(diff.equivalent, 2)
        XCTAssertEqual(diff.changes, 1)
    }

    func testProseIsWhatAModelCanFix() {
        XCTAssertFalse(CorrectionPolicy.hasProse("@alice https://example.com/a 👍 `x` ~/notes"))
        XCTAssertFalse(CorrectionPolicy.hasProse("123 !! 🎉"))
        XCTAssertTrue(CorrectionPolicy.hasProse("ok 👍"))
        XCTAssertTrue(CorrectionPolicy.hasProse("café"))
    }

    func testAnEditorsOwnHintIsNoDraft() {
        XCTAssertTrue(CorrectionPolicy.isPlaceholder("Type a message\n", hints: ["Type a message"]))
        XCTAssertFalse(CorrectionPolicy.isPlaceholder("Type a message to Bob", hints: ["Type a message"]))
        XCTAssertFalse(CorrectionPolicy.isPlaceholder("  ", hints: [""]))
        XCTAssertFalse(CorrectionPolicy.isPlaceholder("hello", hints: []))
    }

    func testWidenedDeletionsNeverOverlapTheirNeighbours() {
        // Review finding: past the join limit, overlapping widened ranges made a negative gap and crashed.
        let typos = Array(repeating: "teh", count: 24).joined(separator: " ")
        for (before, after) in [("an a, apple " + typos, "a apple " + typos.replacingOccurrences(of: "teh", with: "the")),
                                ("an a, apple", "a apple"), ("xx yy", "yy"), ("a  b", "a b")] {
            let edits = TextEdits.between(before, after)
            for (first, second) in zip(edits, edits.dropFirst()) { XCTAssertLessThan(NSMaxRange(first.range), second.location, before) }
            XCTAssertEqual(CorrectionPolicy.applying(edits, to: before), after, before)
        }
    }

    func testALongDraftWithTwoTyposIsNoRewrite() {
        // Review finding: a long draft's diff collapses into one hunk, which used to count as rewritten.
        let words = String(repeating: "word ", count: 700)
        XCTAssertFalse(CorrectionPolicy.isRewrite("the " + words + "small", of: "teh " + words + "smal"))
        XCTAssertTrue(CorrectionPolicy.isRewrite(String(repeating: "mot ", count: 700), of: words))
    }
}
