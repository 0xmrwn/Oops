import XCTest
@testable import OopsCore

final class InputProxyTests: XCTestCase {
    func testMonacoInputRequiresItsEditorAncestor() {
        XCTAssertTrue(InputProxy.matches(classes: ["inputarea", "monaco-mouse-cursor-text"], ancestors: [["view-lines"], ["monaco-editor", "focused"]]))
        XCTAssertFalse(InputProxy.matches(classes: ["inputarea"], ancestors: [["message-composer"]]))
        XCTAssertFalse(InputProxy.matches(classes: ["message"], ancestors: [["monaco-editor"]]))
        XCTAssertFalse(InputProxy.matches(classes: [], ancestors: []))
    }

    func testNativeCodeEditorRequiresBothDescriptionAndCodeAncestor() {
        XCTAssertTrue(InputProxy.matches(classes: [], ancestors: [], roleDescription: "editor", ancestorSubroles: ["AXUnknown", "AXCodeStyleGroup"]))
        XCTAssertFalse(InputProxy.matches(classes: [], ancestors: [], roleDescription: "editor", ancestorSubroles: ["AXDocument"]))
        XCTAssertFalse(InputProxy.matches(classes: [], ancestors: [], roleDescription: "text entry area", ancestorSubroles: ["AXCodeStyleGroup"]))
    }
}
