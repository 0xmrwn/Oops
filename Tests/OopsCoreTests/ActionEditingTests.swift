import XCTest
@testable import OopsCore

final class ActionEditingTests: XCTestCase {
    func testBlankActionIsUntouchedAndTitledNewAction() {
        var action = Action.blank(at: .upRight)
        XCTAssertTrue(action.isUntouched)
        XCTAssertEqual(action.title, "New action")
        XCTAssertEqual(action.symbol, "sparkles")
        action.name = "  \n"
        XCTAssertTrue(action.isUntouched)
        action.name = "Tidy"
        XCTAssertFalse(action.isUntouched)
        XCTAssertEqual(action.title, "Tidy")
    }

    func testCanAddNeedsAFreePlaceAndRoom() throws {
        var library = ActionLibrary.starters
        XCTAssertFalse(library.canAdd(at: .up))
        XCTAssertTrue(library.canAdd(at: .upRight))
        for place in [ActionPlace.upRight, .downRight, .downLeft, .upLeft] {
            var action = Action.blank(at: place)
            action.name = "Extra"
            try library.add(action)
        }
        for place in ActionPlace.allCases { XCTAssertFalse(library.canAdd(at: place)) }
    }

    func testDraftJoinsTheLibraryOnlyOnceWritten() {
        var library = ActionLibrary.starters
        var draft = Action.blank(at: .upRight)
        draft.symbol = "globe"
        XCTAssertEqual(library.apply(draft, draft: draft), draft)
        XCTAssertEqual(library.actions.count, 4)
        draft.instruction = "Expand"
        XCTAssertNil(library.apply(draft, draft: draft))
        XCTAssertEqual(library.actions.count, 5)
        XCTAssertEqual(library.action(at: .upRight)?.instruction, "Expand")
    }

    func testEditToASavedActionLeavesTheDraft() {
        var library = ActionLibrary.starters
        let draft = Action.blank(at: .upRight)
        var saved = library.actions[0]
        saved.name = "Sharper"
        XCTAssertEqual(library.apply(saved, draft: draft), draft)
        XCTAssertEqual(library.actions[0].name, "Sharper")
    }

    func testDraftAtATakenPlaceStaysADraft() {
        var library = ActionLibrary.starters
        var draft = Action.blank(at: .up)
        draft.name = "Clash"
        XCTAssertEqual(library.apply(draft, draft: draft), draft.normalized())
        XCTAssertEqual(library.actions.count, 4)
        XCTAssertNotEqual(library.action(at: .up)?.name, "Clash")
    }
}
