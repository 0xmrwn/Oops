import XCTest
@testable import OopsCore

final class CopiedHTMLTests: XCTestCase {
    func testMalformedTagCannotStallCopyProof() {
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = CopiedHTML.inlineText("<" + String(repeating: " ", count: 16_000))
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    }

    func testQuillCopyRetainsMentionAndUnicode() {
        let html = "<meta charset='utf-8'>مرحبا&nbsp;بالفريق،&nbsp;تم&nbsp;تحديت&nbsp;الخطة&nbsp;<span class=\"mention\" data-name=\"Alice Martin\">\u{FEFF}<span contenteditable=\"false\">@Alice Martin</span>\u{FEFF}</span>&nbsp;واصبحت&nbsp;الأولويات&nbsp;واضحة&nbsp;الآن"
        let plain = "مرحبا بالفريق، تم تحديت الخطة  واصبحت الأولويات واضحة الآن"
        let expected = "مرحبا بالفريق، تم تحديت الخطة @Alice Martin واصبحت الأولويات واضحة الآن"
        XCTAssertFalse(DisplayOrder.copied(plain, matches: expected))
        let rich = CopiedHTML.inlineText(html)?.replacingOccurrences(of: "\u{FEFF}", with: "")
        XCTAssertNotNil(rich)
        XCTAssertTrue(rich.map { DisplayOrder.copied($0, matches: expected) } ?? false)
        XCTAssertFalse(rich.map { DisplayOrder.copied($0, matches: expected.replacingOccurrences(of: " @", with: "\n\n@")) } ?? true)
    }

    func testOnlyInlineMarkupCanSupplyTheSecondReading() {
        XCTAssertEqual(CopiedHTML.inlineText("<span>teh <b>@Alice</b> &amp; smal</span>"), "teh @Alice & smal")
        for html in ["<p>one</p><p>two</p>", "one<br>two", "<div>one</div>", "<span>one\ntwo</span>",
                     "one&#10;two", "<img alt='@Alice' src='https://example.com/image'>", "<script>text</script>",
                     "<style>text</style>", "<body hidden><span>text</span></body>", "<span hidden>text</span>", "<span h\u{0}idden>text</span>", "<head><title>fake</title></head><span>text</span>", "<span style='display:none'>text</span>", "<!DOCTYPE html><span>text</span>",
                     "<?xml version='1.0'?><span>text</span>", String(repeating: "a", count: 262_145)] {
            XCTAssertNil(CopiedHTML.inlineText(html), String(html.prefix(80)))
        }
    }

    func testRichCopyCannotHideMovedProtectedDelimiters() {
        let copied = CopiedHTML.inlineText("<span>`cod` and @Alice</span>")
        XCTAssertTrue(copied.map { DisplayOrder.copied($0, matches: "`cod` and @Alice") } ?? false)
        XCTAssertFalse(copied.map { DisplayOrder.copied($0, matches: "cod and `@Alice`") } ?? true)
        XCTAssertFalse(copied.map { DisplayOrder.copied($0, matches: "`cod and` @Alice") } ?? true)
    }
}
