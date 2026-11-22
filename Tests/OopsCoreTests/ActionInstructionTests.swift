import XCTest
@testable import OopsCore

final class ActionInstructionTests: XCTestCase {
    private let mark = "\u{FFFC}"

    func testInsertAtTheEndGoesInsideTheFullStop() {
        let result = ActionInstruction.insertion(in: "Make the text shorter.", caret: nil)
        XCTAssertEqual(result.location, 21)
        XCTAssertEqual(result.text, " " + mark)
    }

    func testInsertAtTheEndAfterTrailingNewlines() {
        XCTAssertEqual(ActionInstruction.insertion(in: "Fix it.\n\n", caret: nil).location, 6)
    }

    func testInsertAtTheCaretSpacesItFromWords() {
        let inside = ActionInstruction.insertion(in: "Translateinto", caret: 9)
        XCTAssertEqual(inside.location, 9)
        XCTAssertEqual(inside.text, " " + mark + " ")
        XCTAssertEqual(ActionInstruction.insertion(in: "a .", caret: 2).text, mark)
    }

    func testInsertIntoEmpty() {
        let result = ActionInstruction.insertion(in: "", caret: nil)
        XCTAssertEqual(result.location, 0)
        XCTAssertEqual(result.text, mark)
    }

    func testPastedTextLosesTheMark() {
        XCTAssertEqual(ActionInstruction.pasted("a\(mark)b\(mark)"), "ab")
    }

    func testRemovingTheChoiceClosesTheGap() {
        XCTAssertEqual(ActionInstruction.removingChoice(from: "Translate the text into \(mark). Keep names."), "Translate the text into. Keep names.")
        XCTAssertEqual(ActionInstruction.removingChoice(from: "Rewrite in a \(mark) tone."), "Rewrite in a tone.")
        XCTAssertEqual(ActionInstruction.removingChoice(from: "No mark here."), "No mark here.")
    }

    func testNextEmptyFollowsRingOrder() {
        XCTAssertEqual(ActionChoice(name: "L", values: [.up: "French"]).nextEmpty(), .right)
        XCTAssertEqual(ActionChoice(name: "L", values: [.up: "French"]).nextEmpty(skipping: .right), .down)
        XCTAssertEqual(ActionChoice(name: "L", values: [.up: ""]).nextEmpty(), .up)
        XCTAssertEqual(ActionChoice.empty.nextEmpty(), .up)
        let full = ActionChoice(name: "L", values: Dictionary(uniqueKeysWithValues: ActionPlace.allCases.map { ($0, "x") }))
        XCTAssertNil(full.nextEmpty())
    }

    func testSettingAnEmptyValueFreesThePlace() {
        let choice = ActionChoice(name: "L", values: [.up: "French"])
        XCTAssertNil(choice.setting("", at: .up).values[.up])
        XCTAssertEqual(choice.setting("Dutch", at: .upRight).values[.upRight], "Dutch")
    }

    func testRemovingTheMarkDropsTheChoice() {
        let action = Action(symbol: "sparkles", name: "x", instruction: "x", choice: .empty, place: .up)
        XCTAssertNil(action.normalized().choice)
    }

    func testRemovingTheChoiceLeavesTheRestOfTheTextAlone() {
        let text = "Keep « oui ! » unchanged  and  spaced \(mark), as ( written ) ."
        XCTAssertEqual(ActionInstruction.removingChoice(from: text), "Keep « oui ! » unchanged  and  spaced, as ( written ) .")
        XCTAssertEqual(ActionInstruction.removingChoice(from: "Say \(mark)"), "Say")
        XCTAssertEqual(ActionInstruction.removingChoice(from: "\(mark) first  words"), "first  words")
    }

    func testADeletedChoiceComesBackOnlyWithUndo() {
        let configured = ActionChoice(name: "Language", values: [.up: "French"])
        var action = Action(symbol: "sparkles", name: "T", instruction: "Into \(mark).", choice: configured, place: .up)
        var memory = ActionChoiceMemory()
        memory.apply(instruction: "Into .", to: &action)
        XCTAssertNil(action.choice)
        var undone = action
        var undoMemory = memory
        undoMemory.apply(instruction: "Into \(mark).", to: &undone)
        XCTAssertEqual(undone.choice, configured)
        memory.forget()
        memory.apply(instruction: "Into \(mark).", to: &action)
        XCTAssertEqual(action.choice, .empty)
    }
}
