import OopsCore
import SwiftUI

/// One action on one page: its header (back, icon, name).
struct ActionEditor: View {
    let store: ProviderStore
    let navigation: ActionsNavigation
    let id: UUID
    var library = ActionLibraryModel.shared

    private var action: Action { library.action(id) ?? .blank(at: .up) }

    private func bind<Value>(_ path: WritableKeyPath<Action, Value>) -> Binding<Value> {
        Binding(get: { action[keyPath: path] }, set: { value in library.update(id) { $0[keyPath: path] = value } })
    }

    var body: some View { VStack(alignment: .leading, spacing: 20) { header } }

    /// `DrillHeader`'s row with the title made the name field and the icon made a button.
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: navigation.back) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.settingsGlass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .keyboardShortcut("[", modifiers: .command)
            // Reached with ⌘[ rather than Tab, so it never takes the window's first focus ring.
            .focusable(false)
            .help("Back to Actions · ⌘[")
            .accessibilityLabel("Back to Actions")
            Button {} label: {
                Image(systemName: action.symbol).font(.system(size: 15, weight: .medium)).frame(width: 18, height: 18)
            }
            .buttonStyle(.settingsGlass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(true)
            .accessibilityLabel("Icon")
            WellField(title: "Name", text: bind(\.name), font: .system(size: 20, weight: .semibold), height: 36)
        }
    }
}

/// A one-line text field as a well, the look the shortcut field and the prompt editor share. Its edge marks focus
/// only as `FocusRings` allows.
struct WellField: View {
    let title: String
    @Binding var text: String
    var submit: () -> Void = {}
    var font: Font = .body
    var height: CGFloat = 32
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var restingEdge: Double { contrast == .increased ? 0.4 : colorScheme == .dark ? 0.14 : 0.22 }

    var body: some View {
        let marked = focused && FocusRings.shared.shown
        TextField(title, text: $text, prompt: Text(title)).textFieldStyle(.plain).font(font).foregroundStyle(.primary).focused($focused)
            .onSubmit(submit)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(marked ? 0.75 : restingEdge), lineWidth: marked ? 1.5 : 1))
    }
}
