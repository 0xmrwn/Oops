import OopsCore
import SwiftUI

/// Runs with, Agent side: Claude Code, its model and level, and what the agent may do. Without a working Claude Code it
/// says so and leads to Providers.
struct RunsWithAgent: View {
    let store: ProviderStore
    @Binding var runsWith: ActionRunsWith
    var state = State.live

    /// Whether Claude Code is asked of the store, or fixed for a snapshot.
    enum State { case live, ready, unavailable(String) }

    private var problem: String? {
        switch state {
        case .live: store.agentProblem
        case .ready: nil
        case .unavailable(let text): text
        }
    }

    var body: some View {
        if let problem { unavailable(problem) } else { available }
    }

    private func unavailable(_ problem: String) -> some View {
        VStack(spacing: 0) {
            Button { store.wantsProvidersPage = true } label: {
                HStack(spacing: 14) {
                    Image("ClaudeMark", bundle: .main).renderingMode(.template).resizable().interpolation(.high).foregroundStyle(.primary)
                        .frame(width: 18, height: 18).frame(width: 24).accessibilityHidden(true)
                    Text("Claude Code").fontWeight(.semibold)
                    Spacer(minLength: 8)
                    StatusBadge(problem, ok: false)
                    Chevron()
                }
                .padding(.vertical, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Providers")
            .accessibilityLabel("Claude Code, \(problem)")
            .accessibilityHint("Opens Providers")
            HarnessRow(name: "Codex", mark: "CodexMark", selected: false, available: false)
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }

    @ViewBuilder private var available: some View {
        let model = store.agentModel(runsWith.agent)
        VStack(spacing: 0) {
            HarnessRow(name: "Claude Code", mark: "ClaudeMark", selected: true, available: true)
            HarnessRow(name: "Codex", mark: "CodexMark", selected: false, available: false)
            SettingsDivider().padding(.vertical, 2)
            SettingRow(symbol: "cpu", title: "Model") {
                let claude = store.provider("claude-code")
                RunModelButton(store: store, title: "Model", mark: model == nil ? nil : claude, label: model?.name ?? "Loading models",
                               enabled: model != nil, needsProvider: false, groups: claude.map { [($0, store.agentModels)] } ?? [],
                               current: model.map { .init(providerID: "claude-code", modelID: $0.id) }) { choice in
                    guard let choice, let picked = store.agentModels.first(where: { $0.id == choice.modelID }) else { return }
                    runsWith.agent.model = picked.id
                    runsWith.agent.effort = ModelSelection.nearestEffort(runsWith.agent.effort, in: picked)
                }
            }
            if let model, !model.efforts.isEmpty {
                ReasoningRow(model: model, selection: ModelSelection.nearestEffort(runsWith.agent.effort, in: model) ?? "") {
                    runsWith.agent.effort = $0
                }
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
        VStack(spacing: 0) {
            AgentSwitchRow(symbol: "globe", title: "Search the web", isOn: $runsWith.agent.searchWeb,
                           tip: "The agent can search and read web pages, and words from your text may appear in its searches. "
                               + "Expect a slower run, from several seconds to a few minutes.")
            AgentSwitchRow(symbol: "terminal", title: "Run commands", isOn: $runsWith.agent.runCommands,
                           tip: "Lets the agent run commands in a sandbox. They can't change your files, reach the network or read your "
                               + "home folder, apart from your skills when your Claude Code setup is on. They can read other files on "
                               + "this Mac, such as apps and shared temporary files. Skills that run scripts need this.")
            AgentSwitchRow(symbol: "person.crop.circle", title: "Use my Claude Code setup", isOn: $runsWith.agent.usesSetup,
                           tip: "Loads your Claude Code skills and instruction file. A skill written in the instruction needs this; "
                               + "it adds about a second to each run.")
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }
}
