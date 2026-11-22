import AppKit
import OopsCore
import SwiftUI

/// One action on one page: its header (back, icon, name), the instruction as a sentence in which the one choice it may
/// ask for is a pill at the place it applies, Runs with and Try in one card, and Delete. Every edit applies at once.
struct ActionEditor: View {
    let store: ProviderStore
    let navigation: ActionsNavigation
    let id: UUID
    var library = ActionLibraryModel.shared
    @State private var pickingIcon = false
    @State private var tryOpen = DebugFlags.settingsActionPage == "try"
    @State private var confirmingDelete = DebugFlags.settingsActionPage == "delete"
    @State private var instruction = InstructionController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var action: Action { library.action(id) ?? .blank(at: .up) }

    /// An agent that loads the person's setup is the one that runs their skills, so only then does the instruction
    /// know them.
    private var usesSkills: Bool { action.runsWith.kind == .agent && action.runsWith.agent.usesSetup }

    private func bind<Value>(_ path: WritableKeyPath<Action, Value>) -> Binding<Value> {
        Binding(get: { action[keyPath: path] }, set: { value in library.update(id) { $0[keyPath: path] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            VStack(alignment: .leading, spacing: 12) {
                InstructionEditor(library: library, navigation: navigation, id: id, controller: instruction,
                                  skills: usesSkills ? store.skillCatalog.names ?? [] : [])
                // One choice per action: once its pill is in the sentence, the pill is the control.
                if action.choice == nil {
                    Button { instruction.insertChoice() } label: { Label("Insert a choice", systemImage: "plus") }
                        .buttonStyle(.settingsGlass)
                        .controlSize(.large)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: action.choice == nil)
            card
            delete
        }
        .task { await launchPage() }
        // Asked once Claude Code works, and again when it comes to, for an action that can name skills.
        .task(id: usesSkills && store.agentReady) {
            if usesSkills, store.agentReady { store.skillCatalog.loadIfNeeded(runtime: store.claudeRuntime) }
        }
    }

    /// Launch-only: `-SettingsPreviewActionPage icons|choice|insert|eight` opens that state once the page has settled.
    private func launchPage() async {
        guard let page = DebugFlags.settingsActionPage, ["icons", "choice", "insert", "eight"].contains(page) else { return }
        try? await Task.sleep(for: .seconds(0.8))
        switch page {
        case "icons": pickingIcon = true
        case "insert": instruction.insertChoice()
        default: instruction.openChoice()
        }
    }

    // MARK: Header: back, icon, name

    /// `DrillHeader`'s row with the title made the name field and the icon made its picker's button.
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
            Button { pickingIcon = true } label: {
                Image(systemName: action.symbol).font(.system(size: 15, weight: .medium)).frame(width: 18, height: 18)
            }
            .buttonStyle(.settingsGlass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Change icon")
            .accessibilityLabel("Icon")
            // Beside the button, not under it: under it the picker hung out past the window's edge.
            .popover(isPresented: $pickingIcon, arrowEdge: .trailing) {
                IconPicker(symbol: bind(\.symbol)) { pickingIcon = false }
                    .modifier(EscapeCloses { pickingIcon = false })
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsPageWillChange)) { _ in pickingIcon = false }
            WellField(title: "Name", text: bind(\.name), font: .system(size: 20, weight: .semibold), height: 36)
        }
    }

    // MARK: Runs with, and Try beneath it

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            runsWithRow
            tryRows
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }

    private var runsWithRow: some View {
        let summary = store.runsWithSummary(action.runsWith)
        return Button { navigation.openRunsWith(.action(id)) } label: {
            SettingRow(symbol: "cpu", title: "Runs with") {
                HStack(spacing: 10) {
                    Text(summary).secondaryText().lineLimit(1).truncationMode(.middle)
                    Chevron()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Runs with")
        .accessibilityValue(summary)
    }

    @ViewBuilder private var tryRows: some View {
        Button { withAnimation(SettingsMotion.swap(reduceMotion)) { tryOpen.toggle() } } label: {
            SettingRow(symbol: "text.cursor", title: "Try") {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                    .rotationEffect(.degrees(tryOpen ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Try")
        .accessibilityValue(tryOpen ? "Open" : "Closed")
        if tryOpen {
            ActionTryPanel(store: store, action: action).padding(.top, 6).padding(.bottom, 12)
                .transition(.opacity)
        }
    }

    // MARK: Delete

    /// Asked in place: the button becomes the question and its two answers. No dialog, so nothing takes focus by
    /// itself as an alert's default button does.
    private var delete: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if confirmingDelete {
                Text("Delete \(action.title)?").secondaryText()
                Button("Cancel") { withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = false } }
                    .buttonStyle(.settingsGlass)
                Button("Delete") {
                    withAnimation(SettingsMotion.drill(reduceMotion)) {
                        library.remove(id)
                        navigation.backToWheel()
                    }
                }
                .buttonStyle(.settingsGlass).foregroundStyle(.red)
                .accessibilityLabel("Confirm delete")
            } else {
                Button { withAnimation(.easeOut(duration: 0.15)) { confirmingDelete = true } } label: {
                    Label("Delete action", systemImage: "trash")
                }
                .buttonStyle(.settingsGlass)
            }
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

/// Escape closes a popover whose fields never take the keyboard from the window (Settings' popovers don't).
struct EscapeCloses: ViewModifier {
    let close: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53 else { return event }
                    close()
                    return nil
                }
            }
            .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
