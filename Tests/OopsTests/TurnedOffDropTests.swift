import AppKit
@testable import Oops
import OopsCore
import Testing

/// What the drops say when the person turned Oops off in the app they're in, and that every other refusal keeps its words.
@MainActor struct TurnedOffDropTests {
    private let notes = TurnedOffApp(name: "Notes", bundleID: "com.apple.Notes")

    @Test func `Fix names the app and offers to turn it back on there`() {
        let failure = CorrectionSession.failure(CorrectionError.turnedOff(notes), at: .capture, allowed: true)
        #expect(failure.label == "Off in Notes")
        #expect(failure.remedy == .turnOn(TurnedOffApp(name: "Notes", bundleID: "com.apple.Notes")))
        #expect(CorrectionError.turnedOff(notes).localizedDescription == "Oops is off in Notes.")
    }

    @Test func `every other refusal at capture still can't edit here`() {
        let refusals = [
            CorrectionError.message("Oops stays out of terminals and password managers."),
            .message(EditorAccess.secureFieldMessage),
            .message("No editable composer has focus."),
        ]
        for refusal in refusals {
            let failure = CorrectionSession.failure(refusal, at: .capture, allowed: true)
            #expect(failure.label == "Can’t edit here", "\(refusal)")
            #expect(failure.remedy == nil, "\(refusal)")
        }
        #expect(CorrectionSession.failure(CorrectionError.message("x"), at: .capture, allowed: false).remedy == .settings)
    }

    @Test func `a long app name is cut in Fix's drop, a short one is whole`() {
        // Fix's drop: its panel less the insets, the eye slot and the button's cap, with their gaps.
        let room = CapsulePanel.standard.width - 2 * 14 - 2 * (EyesDropView.drop + 6)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        #expect(DropLabel.fitted(["Off in Microsoft Word"], room: room, font: font, divider: 15) == ["Off in Microsoft Word"])
        let long = DropLabel.fitted(["Off in Microsoft Outlook"], room: room, font: font, divider: 15)
        #expect(long == ["Off in Microsoft…"])
        #expect(DropLabel.width(long, font: font, divider: 15) <= room)
    }

    @Test func `Actions name the app and offer to turn it back on`() {
        let failure = ActionFailure.capture(CorrectionError.turnedOff(notes))
        #expect(failure.reason == .turnedOff)
        #expect(failure.label.text == "Off in Notes")
        #expect(failure.label.remedy == .turnOn(notes))
        #expect(ActionFailure.capture(CorrectionError.message("No editable composer has focus.")).reason == .capture)
    }

    @Test func `Dictate names the app in front, or says this app`() {
        #expect(DictationSession.ending(.refused(.appTurnedOff), turnedOff: notes) == .failed(.turnedOff(notes)))
        #expect(DictationDropState.failed(.turnedOff(notes)).text == "Off in Notes")
        #expect(DictationDropState.failed(.turnedOff(nil)).text == "Turned off in this app")
        #expect(DictationSession.ending(.refused(.appDenied), turnedOff: notes) == .failed(.appDenied))
    }
}
