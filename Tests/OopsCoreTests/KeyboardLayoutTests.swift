import XCTest
@testable import OopsCore

final class KeyboardLayoutTests: XCTestCase {
    func testHyperLettersMatchActiveKeyboardLayout() throws {
        for letter in ["w", "r"] {
            let code = try XCTUnwrap(KeyboardLayout.keyCode(for: letter))
            guard let emitted = KeyboardLayout.character(for: code) else { throw XCTSkip("No hardware Unicode layout is available") }
            XCTAssertEqual(emitted.lowercased(), letter, "The global shortcut must use the letter, not its physical US position")
        }
    }
}
