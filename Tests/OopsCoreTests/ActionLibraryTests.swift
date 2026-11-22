import OopsCore
import XCTest

final class ActionLibraryTests: XCTestCase {
    func testPlacesAndChoiceOrder() {
        XCTAssertEqual(ActionPlace.allCases, [.up, .right, .down, .left, .upRight, .downRight, .downLeft, .upLeft])
        XCTAssertEqual(ActionPlace.allCases.filter(\.isDiagonal), [.upRight, .downRight, .downLeft, .upLeft])
        let choice = ActionChoice(name: "Tone", values: [.upLeft: "Firm", .up: "Direct", .right: " \n", .downRight: "Dry"])
        XCTAssertEqual(choice.ordered, ["Direct", "Dry", "Firm"])
    }

    func testOccupiedPlaceAndFullWheel() throws {
        var library = ActionLibrary.starters
        func action(_ place: ActionPlace) -> Action { Action(symbol: "star", name: "Expand", instruction: "Expand this", place: place) }
        XCTAssertThrowsError(try library.add(action(.up))) { XCTAssertEqual($0 as? ActionLibraryError, .placeTaken) }
        var copy = library.actions[0]
        copy.place = .upRight
        XCTAssertThrowsError(try library.add(copy)) { XCTAssertEqual($0 as? ActionLibraryError, .duplicate) }
        for place in ActionPlace.allCases where place.isDiagonal { try library.add(action(place)) }
        XCTAssertThrowsError(try library.add(action(.left))) { XCTAssertEqual($0 as? ActionLibraryError, .full) }
        XCTAssertEqual(library.actions.count, 8)
    }

    func testMovesSwapOnlyTheTwoPlacesAndRemovalLeavesAHole() {
        var library = ActionLibrary.starters
        let original = library.actions
        library.move(original[0].id, to: .upLeft)
        XCTAssertNil(library.action(at: .up))
        XCTAssertEqual(library.actions.map(\.place), [.upLeft, .right, .down, .left])
        library.move(original[0].id, to: .down)
        XCTAssertEqual(library.actions.map(\.place), [.down, .right, .upLeft, .left])
        XCTAssertEqual(library.actions.map(\.id), original.map(\.id))
        library.remove(original[1].id)
        XCTAssertEqual(library.actions.map(\.place), [.down, .upLeft, .left])
    }

    func testNormalizationAndUpdate() {
        var library = ActionLibrary.starters
        var action = library.actions[0]
        let mark = Action.choiceMark
        action.instruction = "a" + mark + "b" + mark + "c"
        library.update(action)
        XCTAssertEqual(library.action(at: .up)?.instruction, "a" + mark + "bc")
        XCTAssertEqual(library.action(at: .up)?.choice, action.choice)
        action.instruction = "abc"
        XCTAssertNil(action.normalized().choice)
        action.choice = nil
        action.instruction = mark + "abc" + mark
        XCTAssertEqual(action.normalized().instruction, "abc")
    }
}
