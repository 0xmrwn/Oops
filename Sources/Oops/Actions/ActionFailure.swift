import Foundation
import OopsCore

/// Why an action wrote nothing, in Actions' own words: a reason the drop names in a few words (`label`), and the
/// message its tooltip shows.
struct ActionFailure: Error, Equatable {
    enum Reason: String, Sendable {
        case empty, tooLong, secure, capture, agentRun, noModel, offline, slow, signIn, limit, setup, model, output, restore, partial
    }
    let reason: Reason
    let message: String
    init(_ reason: Reason, _ message: String) { self.reason = reason; self.message = message }

    static let agentRun = ActionFailure(.agentRun, "This action runs as an agent, which Oops can’t do yet. Nothing was changed.")
    static let noModel = ActionFailure(.noModel, "Add a provider in Settings → Providers to run actions.")
    static let slow = ActionFailure(.slow, "The model took longer than 40 seconds. Nothing was changed.")
    static let nothingToRestore = ActionFailure(.restore, "There’s no recent action to restore.")
    static let changedSince = ActionFailure(.restore, "The draft changed after the action, so restoring it would overwrite newer work.")

    static let partlyWritten = ActionFailure(.partial, "The draft was changed in part and could not be put back. Check it; the answer is ready to copy.")

    /// Why the draft couldn't be read.
    static func capture(_ error: Error) -> ActionFailure {
        if let failure = error as? ActionFailure { return failure }
        if let empty = error as? EmptyDraft {
            return ActionFailure(.empty, "There’s no text here to run an action on." + (empty.detail.isEmpty ? "" : " " + empty.detail))
        }
        switch error as? CorrectionError {
        case .failure(.tooLong, _)?:
            return ActionFailure(.tooLong, "Actions work on up to \(ActionPrompt.maximumLength.formatted()) characters at once. Select a part of this draft.")
        case .failure(.empty, _)?: return ActionFailure(.empty, "There’s no text here to run an action on.")
        case .message(EditorAccess.secureFieldMessage)?: return ActionFailure(.secure, "Actions don’t read password or code fields.")
        default: return ActionFailure(.capture, error.localizedDescription)
        }
    }

    /// Why the model gave nothing to write.
    static func model(_ error: Error) -> ActionFailure {
        if let failure = error as? ActionFailure { return failure }
        if error is ActionOutputError { return ActionFailure(.output, "The model’s answer had no text to use. Nothing was changed.") }
        let reason: Reason = switch (error as? CorrectionError)?.reason {
        case .offline: .offline
        case .slow: .slow
        case .signIn: .signIn
        case .limit: .limit
        case .setup: .setup
        case .tooLong, .empty, nil: .model
        }
        return ActionFailure(reason, error.localizedDescription)
    }
}

/// How a run or a restore ended.
enum ActionOutcome: Equatable, Sendable { case written, held, restored, cancelled, failed(ActionFailure) }
