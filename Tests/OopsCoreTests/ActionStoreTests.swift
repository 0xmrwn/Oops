import Foundation
import OopsCore
import XCTest

final class ActionStoreTests: XCTestCase {
    private let suite = "ActionStoreTests." + UUID().uuidString
    private lazy var defaults = UserDefaults(suiteName: suite)!
    private lazy var store = ActionStore(defaults: defaults)

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testMissingAndUnreadableLibrariesLoadStarters() throws {
        for value in [nil, Data([0xFF]), try JSONEncoder().encode(ActionLibrary(version: 2))] {
            defaults.set(value, forKey: ActionStore.key)
            let actions = store.load().actions
            XCTAssertEqual(actions.map(\.name), ["Sharpen prompt", "Translate", "Shorten", "Tone"])
            XCTAssertEqual(actions.map(\.place), [.up, .right, .down, .left])
            XCTAssertTrue(actions.allSatisfy { $0.runsWith == .sameAsFix })
            XCTAssertEqual(defaults.data(forKey: "Actions.unreadable"), value)
        }
        defaults.set("broken", forKey: "Actions")
        XCTAssertEqual(store.load(), .starters)
        XCTAssertEqual(defaults.string(forKey: "Actions.unreadable"), "broken")
    }

    func testEmptyWheelStaysEmpty() {
        store.save(ActionLibrary())
        XCTAssertTrue(store.load().actions.isEmpty)
    }

    func testRoundTripPreservesBothRunConfigurationsAndChoicePlaces() throws {
        let model = ActionModelRun(choice: .init(providerID: "local", modelID: "small"), effort: "low")
        let agent = ActionAgentRun(model: "sonnet", effort: "high", searchWeb: false, runCommands: true, usesSetup: true)
        let choice = ActionChoice(name: "Style", values: [.right: "Quick", .downLeft: "Detailed"])
        let action = Action(symbol: "pencil", name: "Explain", instruction: "Explain: " + Action.choiceMark, choice: choice,
                            place: .upLeft, runsWith: .init(kind: .agent, model: model, agent: agent))
        let library = ActionLibrary(actions: [action], typed: .init(model: model))
        store.save(library)
        XCTAssertEqual(store.load(), library)
        let data = try XCTUnwrap(defaults.data(forKey: "Actions"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
        let savedChoice = try XCTUnwrap(actions.first?["choice"] as? [String: Any])
        XCTAssertEqual(savedChoice["values"] as? [String: String], ["right": "Quick", "downLeft": "Detailed"])
    }

    func testDuplicatePlacesKeepFirstInStoredOrder() {
        let actions = ActionPlace.allCases.reversed().map { Action(symbol: "star", name: $0.rawValue, instruction: "Expand", place: $0) }
        var duplicates = actions
        duplicates.insert(ActionLibrary.starters.actions[0], at: 7)
        store.save(ActionLibrary(actions: duplicates))
        XCTAssertEqual(store.load().actions, Array(duplicates.prefix(8)))
    }
}
