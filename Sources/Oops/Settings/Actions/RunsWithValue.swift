import OopsCore
import SwiftUI

/// The editor's Runs with value in two lines: what runs (mark, model, level), then what it may do, or that it follows
/// Fix, or what stops it. A plain model has no second line and sits centred.
struct RunsWithValue: View {
    let store: ProviderStore
    let summary: ActionRunSummary

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            whatRuns
            mayDo.font(.subheadline)
        }
    }

    /// The model is what someone looks for, so it is the one medium-weight word and the last to give way: the level
    /// goes whole before the name truncates, and the name truncates in its middle, where an ID repeats itself least.
    @ViewBuilder private var whatRuns: some View {
        if let name = summary.model ?? (summary.agent ? "Claude Code" : nil) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { mark; model(name); level }
                HStack(spacing: 6) { mark; model(name) }
            }
        }
    }

    @ViewBuilder private var mark: some View {
        let opacity = summary.problem == nil ? 1 : 0.6
        if let provider = summary.providerID.flatMap(store.provider) { ProviderMark(provider: provider, size: 14).opacity(opacity) }
        else if summary.agent {
            // Claude Code not set up has no provider to draw, but the run is still Claude Code's.
            Image("ClaudeMark", bundle: .main).renderingMode(.template).resizable().interpolation(.high)
                .foregroundStyle(Color.primary.opacity(opacity)).frame(width: 14, height: 14).accessibilityHidden(true)
        }
    }

    /// A model that can't run steps back to regular weight in Color.primary at a lower opacity: the hierarchical
    /// secondary takes the backdrop's pink on the light glass.
    private func model(_ name: String) -> some View {
        Text(name).fontWeight(summary.problem == nil ? .medium : .regular)
            .foregroundStyle(Color.primary.opacity(summary.problem == nil ? 1 : 0.6))
            .lineLimit(1).truncationMode(.middle)
    }

    @ViewBuilder private var level: some View {
        if summary.problem == nil, let level = summary.level { Text(level).secondaryText().lineLimit(1).fixedSize() }
    }

    @ViewBuilder private var mayDo: some View {
        if let problem = summary.problem {
            StatusBadge(problem, ok: false)
        } else if summary.sameAsFix {
            // A link, not a third run of words: the model follows Fix's.
            HStack(spacing: 3) {
                Image(systemName: "link").font(.system(size: 11, weight: .medium))
                Text("Same as Fix")
            }
            .secondaryText()
        } else if summary.agent {
            // An agent with no tools still says so, or it would read as a plain model through the same provider.
            if summary.permissions.isEmpty { Text("Agent").secondaryText() } else { permissions }
        }
    }

    private var permissions: some View {
        HStack(spacing: 10) {
            ForEach(summary.permissions, id: \.self) { permission in
                HStack(spacing: 3) {
                    Image(systemName: Self.symbol(permission)).font(.system(size: 12, weight: .medium)).imageScale(.medium)
                    Text(permission.label)
                }
                .secondaryText()
            }
        }
    }

    /// The symbols of the Runs with page's switches.
    private static func symbol(_ permission: ActionRunSummary.Permission) -> String {
        switch permission {
        case .web: "globe"
        case .commands: "terminal"
        case .setup: "person.crop.circle"
        }
    }
}
