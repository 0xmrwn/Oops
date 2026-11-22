import OopsCore
import SwiftUI

/// How an action, or an instruction typed in the wheel, runs: a model, or an agent.
struct RunsWithPage: View {
    let store: ProviderStore
    /// What back returns to, for its label.
    let parent: String
    @Binding var runsWith: ActionRunsWith
    let back: () -> Void

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
        }
    }
}
