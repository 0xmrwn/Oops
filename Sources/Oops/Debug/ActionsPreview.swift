#if DEBUG
import Foundation
import OopsCore

/// Launch-only Actions pages for captures (`-SettingsPreviewAction`, `-SettingsPreviewActionPage`, `-SettingsPreviewActionRuns`, `-SettingsPreviewSkills`).
@MainActor enum ActionsPreview {
    static func launch(_ navigation: ActionsNavigation) {
        let library = navigation.library
        switch DebugFlags.settingsAction?.lowercased() {
        case nil: return
        case "typed": navigation.openRunsWith(.typed)
        case "new": if let place = ActionPlace.allCases.first(where: library.library.canAdd(at:)) { navigation.add(at: place) }
        case let name?:
            if let action = library.library.actions.first(where: { $0.name.lowercased().hasPrefix(name) }) { navigation.edit(action.id) }
        }
        guard let id = navigation.editing else { return }
        if DebugFlags.actionsPreview { seed(id, in: library) }
        if ["runs", "picker"].contains(DebugFlags.settingsActionPage) { navigation.openRunsWith(.action(id)) }
    }

    /// States an editor capture needs that the starters don't have; nothing is saved (the library is in memory).
    private static func seed(_ id: UUID, in library: ActionLibraryModel) {
        switch DebugFlags.actionRuns {
        case "model":
            library.update(id) { $0.runsWith = .init(kind: .model, model: .init(choice: .init(providerID: "claude-code", modelID: "haiku"), effort: "low")) }
        case "agent":
            library.update(id) { $0.runsWith = .init(kind: .agent, agent: .init(model: "sonnet", effort: "high", searchWeb: true, runCommands: true)) }
        case "agentSetup":
            library.update(id) { $0.runsWith = .init(kind: .agent, agent: .init(model: "sonnet", effort: "high", searchWeb: false, usesSetup: true)) }
        default: break
        }
        switch DebugFlags.settingsActionPage {
        case "eight":
            library.update(id) { action in
                var choice = action.choice ?? .empty
                for (place, value) in [(ActionPlace.upRight, "Portuguese"), (.downRight, "Dutch"), (.downLeft, "Japanese"), (.upLeft, "Korean")] {
                    choice = choice.setting(value, at: place)
                }
                action.choice = choice
            }
        case "skills":
            library.update(id) {
                $0.instruction = "Run /review on the text, then $summarize it. Ignore /reviewer and $other. Make it \(Action.choiceMark) "
                    + "/review and keep the notes the check flagged, then $summarize every paragraph before you send it back to me."
                $0.choice = $0.choice ?? .empty
            }
        case "long":
            library.update(id) {
                $0.instruction = long()
                $0.choice = $0.choice ?? .empty
            }
        default: break
        }
    }

    private static func long() -> String {
        let choice = Action.choiceMark
        return "Keep product names, code, URLs and anything inside quotation marks exactly as written. Use the register a native speaker "
            + "would use in a professional email, not a literal rendering. Make the text \(choice) without losing its meaning. Keep the "
            + "paragraph breaks and any list structure. Where a sentence is ambiguous, choose the reading that fits the rest of the text. "
            + "If the text mixes languages, keep each part in its language. Dates, numbers and units stay as they are. Never add "
            + "explanations, notes or alternatives: return only the shortened text, and nothing before or after it, not even a greeting "
            + "or a closing line. Keep lists as lists and headings as headings. Keep emphasis where the author put it, and never "
            + "introduce any that was not there."
    }
}
#endif
