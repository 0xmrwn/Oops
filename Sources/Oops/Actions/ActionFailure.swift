import Foundation
import OopsCore

/// Why an action wrote nothing, in Actions' own words: a reason the drop names in a few words (`label`), and the
/// message its tooltip shows.
struct ActionFailure: Error, Equatable {
    enum Reason: String, Sendable {
        case empty, tooLong, secure, capture, agentBusy, sandbox, noModel, offline, slow, signIn, limit, setup, model, output, restore, attachment
    }
    let reason: Reason
    let message: String
    init(_ reason: Reason, _ message: String) { self.reason = reason; self.message = message }

    static let noModel = ActionFailure(.noModel, "Add a provider in Settings → General → Providers to run actions.")
    static let slow = ActionFailure(.slow, "The model took longer than 40 seconds. Nothing was changed.")
    static let nothingToRestore = ActionFailure(.restore, "There’s no recent action to restore.")
    static let changedSince = ActionFailure(.restore, "The draft changed after the action, so restoring it would overwrite newer work.")

    static let attachment = ActionFailure(.attachment, "An action replaces all the text it reads, which would remove the attachment in it. Select the text around it.")

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

    /// One agent run at a time: a ready result still counts, so it isn't lost to a second run.
    static func agentBusy(_ name: String) -> ActionFailure {
        ActionFailure(.agentBusy, "\(name) is still running. Cancel it from the menu bar to start another.")
    }

    /// Why an agent run gave nothing to write.
    static func agent(_ error: Error) -> ActionFailure {
        switch error as? ClaudeAgentError {
        case .sandboxUnavailable?:
            return ActionFailure(.sandbox, "The sandbox that keeps agent runs contained isn’t available, so nothing ran.")
        case .timedOut?: return ActionFailure(.slow, "The agent took longer than 5 minutes. Nothing was changed.")
        case .notInstalled?: return ActionFailure(.setup, "Agent actions run with Claude Code. Install it and sign in from Settings → General → Providers.")
        case .stopped?: return ActionFailure(.model, "The agent stopped before answering. Nothing was changed.")
        case nil:
            if error is ActionOutputError { return ActionFailure(.output, "The agent’s answer had no text to use. Nothing was changed.") }
            return model(error)
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
