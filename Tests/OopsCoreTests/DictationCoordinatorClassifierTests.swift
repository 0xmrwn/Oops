import XCTest
@testable import OopsCore

final class DictationCoordinatorClassifierTests: XCTestCase {
    private typealias Machine = DictationCoordinator

    func testPushToTalkReleaseWhileRecordingDefersRelease() {
        XCTAssertEqual(
            Machine.classifyPttEvent(
                pendingReleaseBinding: nil, isPressed: false, holdToTalk: true, bindingID: "transcribe",
                heldBinding: "transcribe"),
            .deferRelease)
    }

    func testPushToTalkPressMatchingPendingReleaseCancelsRelease() {
        XCTAssertEqual(
            Machine.classifyPttEvent(
                pendingReleaseBinding: "transcribe", isPressed: true, holdToTalk: true,
                bindingID: "transcribe", heldBinding: "transcribe"),
            .cancelRelease)
    }

    func testToggleModePressAndReleasePassThrough() {
        XCTAssertEqual(
            Machine.classifyPttEvent(
                pendingReleaseBinding: "transcribe", isPressed: true, holdToTalk: false,
                bindingID: "transcribe", heldBinding: "transcribe"),
            .passthrough)
        XCTAssertEqual(
            Machine.classifyPttEvent(
                pendingReleaseBinding: nil, isPressed: false, holdToTalk: false, bindingID: "transcribe",
                heldBinding: "transcribe"),
            .passthrough)
    }

    func testPressForDifferentBindingThanPendingReleasePassesThrough() {
        XCTAssertEqual(
            Machine.classifyPttEvent(
                pendingReleaseBinding: "transcribe", isPressed: true, holdToTalk: true,
                bindingID: "transcribe_with_post_process", heldBinding: "transcribe"),
            .passthrough)
    }

    func testPressMatchingPendingReleaseCancelsWithoutRecordingState() {
        XCTAssertEqual(
            Machine.classifyPttEvent(
                pendingReleaseBinding: "transcribe", isPressed: true, holdToTalk: true,
                bindingID: "transcribe", heldBinding: nil),
            .cancelRelease)
    }

    // Busy-pipeline input classification.
    //
    // Toggle-style triggers (signals, command-line flags, pedals that signal on both edges) flip state on
    // every edge. Dropping a press that arrives while the previous pipeline is still processing desyncs
    // the parity: the next edge then starts a recording no one will stop.

    func testTogglePressDuringProcessingRemembersStart() {
        XCTAssertEqual(
            Machine.classifyBusyInput(isPressed: true, mode: .toggle, remembered: nil), .remember)
    }

    func testSecondTogglePressDuringProcessingForgetsPress() {
        XCTAssertEqual(
            Machine.classifyBusyInput(isPressed: true, mode: .toggle, remembered: .locked), .forget)
    }

    func testToggleReleaseDuringProcessingIsIgnored() {
        XCTAssertEqual(
            Machine.classifyBusyInput(isPressed: false, mode: .toggle, remembered: nil), .ignore)
        XCTAssertEqual(
            Machine.classifyBusyInput(isPressed: false, mode: .toggle, remembered: .locked), .ignore)
    }

    func testHoldModesClassifyBusyInputsByPendingState() {
        let cases: [(Bool, Machine.Remembered?, Machine.BusyAction)] = [
            (true, nil, .remember),
            (true, .held, .ignore),
            (true, .locked, .forget),
            (false, nil, .ignore),
            (false, .held, .ignore),
            (false, .locked, .ignore),
        ]

        for mode in [Machine.Activation.pushToTalk, .holdOrToggle] {
            for (isPressed, remembered, expected) in cases {
                XCTAssertEqual(
                    Machine.classifyBusyInput(isPressed: isPressed, mode: mode, remembered: remembered),
                    expected)
            }
        }
    }

    /// Toggle parity across a busy window: an odd number of presses remembers one start, each further
    /// press flips the remembered press off/on again.
    func testTogglePressesAlternateRememberAndForgetWhileBusy() {
        var remembered: Machine.Remembered?
        for expected in [Machine.BusyAction.remember, .forget, .remember] {
            let action = Machine.classifyBusyInput(isPressed: true, mode: .toggle, remembered: remembered)
            XCTAssertEqual(action, expected)
            remembered = action == .remember ? .locked : nil
        }
        XCTAssertNotNil(remembered)
    }
}
