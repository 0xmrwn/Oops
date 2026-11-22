import OopsCore
import SwiftUI

/// How an action, or an instruction typed in the wheel, runs: a model, or an agent.
struct RunsWithPage: View {
    let store: ProviderStore
    /// What back returns to, for its label.
    let parent: String
    @Binding var runsWith: ActionRunsWith
    let back: () -> Void
    /// Snapshots fix Claude Code's state; the page asks the store.
    var agent = RunsWithAgent.State.live

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DrillHeader(title: "Runs with", parent: parent, back: back) {
                Image(systemName: "cpu").font(.system(size: 18, weight: .medium))
            } accessory: {
                // On glass, as everywhere in Settings: on the bare page the pill drew over its own label.
                GlassChoice(title: "Runs with", choices: [(ActionRunsWith.Kind.model, "Model"), (.agent, "Agent")],
                            selection: $runsWith.kind)
                    .padding(3)
                    .glassEffect(.clear, in: .capsule)
            }
            if runsWith.kind == .agent { RunsWithAgent(store: store, runsWith: $runsWith, state: agent) } else { modelSide }
        }
        // A Claude Code installed or signed in meanwhile shows.
        .task { store.refreshClaude() }
    }

    // MARK: Model

    private var modelSide: some View {
        let target = store.actionModel(runsWith.model)
        let follows = target?.followsFix ?? true
        let model = target.flatMap { store.catalogModel($0.choice) }
        return VStack(spacing: 0) {
            SettingRow(symbol: "cpu", title: "Model") {
                RunModelButton(store: store, title: "Model", mark: follows ? nil : target.flatMap { store.provider($0.choice.providerID) },
                               label: follows ? "Same as Fix" : target.map { store.modelName($0.choice) } ?? "Same as Fix",
                               help: follows ? fixHelp : nil, needsProvider: store.actionNeedsProvider, groups: store.actionGroups, current: follows ? nil : target?.choice,
                               leading: "Same as Fix", leadingIsCurrent: follows) { choice in
                    guard let choice else { return runsWith.model.choice = nil }
                    runsWith.model.choice = choice
                    if let model = store.catalogModel(choice) {
                        runsWith.model.effort = ModelSelection.nearestEffort(runsWith.model.effort, in: model)
                    }
                }
            }
            if !follows, let model, !model.efforts.isEmpty {
                ReasoningRow(model: model, selection: target?.settings.effort ?? "") { runsWith.model.effort = $0 }
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }

    /// What Same as Fix runs on, for the button's tooltip.
    private var fixHelp: String {
        guard let model = store.currentModel else { return "Fix's model" }
        let level = ModelSelection.lightest(model).effort.map { ", at its lightest level, \(ModelSelection.effortName($0))" } ?? ""
        return "Fix's model, \(model.name)\(level)"
    }
}
