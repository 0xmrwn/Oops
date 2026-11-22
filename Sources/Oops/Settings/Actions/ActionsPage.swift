import Observation
import OopsCore
import SwiftUI

/// Where the Actions tab is: the wheel, an action's editor, or Runs with over either; and the choice panel.
@Observable @MainActor final class ActionsNavigation {
    enum RunsWith: Hashable { case action(UUID), typed }
    struct Level: Hashable { var editing: UUID?, runsWith: RunsWith? }
    /// The action whose editor shows; nil on the wheel.
    private(set) var editing: UUID?
    /// Runs with, over the editor (`.action`) or over the wheel (`.typed`).
    private(set) var runsWith: RunsWith?
    /// The choice panel, while open.
    var choice: ChoiceRequest?
    /// The last move went one page deeper: the page shown slides in from the right, else from the left.
    private(set) var forward = true
    @ObservationIgnored let library: ActionLibraryModel

    init(library: ActionLibraryModel = .shared) { self.library = library }

    var level: Level { Level(editing: editing, runsWith: runsWith) }

    func edit(_ id: UUID) { choice = nil; forward = true; editing = id; runsWith = nil }
    func add(at place: ActionPlace) { if let id = library.startNew(at: place) { edit(id) } }
    func openRunsWith(_ target: RunsWith) { choice = nil; forward = true; runsWith = target }

    /// One page up: Runs with goes back to what it was opened from; the editor goes back to the wheel, dropping a new
    /// action nobody wrote anything in.
    func back() {
        choice = nil
        forward = false
        if runsWith != nil { runsWith = nil; return }
        leaveEditor()
    }

    /// The tab chosen again, or the action deleted: straight back to the wheel.
    func backToWheel() { choice = nil; forward = false; runsWith = nil; leaveEditor() }

    private func leaveEditor() {
        if let id = editing, library.draft?.id == id { library.discardDraft() }
        editing = nil
    }
}

/// The choice panel's request: the pill's frame and the window's size, in the window's top-left space, and whether it
/// opens to name a choice just inserted.
struct ChoiceRequest: Equatable {
    var anchor: CGRect
    var bounds: CGSize
    var naming = false
}

extension ActionsNavigation {
    /// Launch-only: `-SettingsPreviewAction` (Debug builds); otherwise the wheel.
    static func launchPreview() -> ActionsNavigation {
        let navigation = ActionsNavigation()
        #if DEBUG
        ActionsPreview.launch(navigation)
        #endif
        return navigation
    }
}

/// Actions: its shortcut and the wheel of saved actions, or one action's editor, or Runs with.
struct ActionsPage: View {
    let store: ProviderStore
    let navigation: ActionsNavigation
    /// The pointer, for the wheel's eyes.
    let spare: SpareSpaceModel
    var library = ActionLibraryModel.shared
    @State private var shortcutError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let target = navigation.runsWith {
                RunsWithPage(store: store, parent: parentTitle(target), runsWith: runsWithBinding(target), back: navigation.back)
                    .drillPane(edge: 1, reduceMotion: reduceMotion)
            } else if let id = navigation.editing, library.action(id) != nil {
                ActionEditor(store: store, navigation: navigation, id: id).id(id)
                    .drillPane(edge: navigation.forward ? 1 : -1, reduceMotion: reduceMotion)
            } else {
                wheel.drillPane(edge: -1, reduceMotion: reduceMotion)
            }
        }
        .animation(SettingsMotion.drill(reduceMotion), value: navigation.level)
        .animation(.easeOut(duration: 0.15), value: ShortcutSettings.shared.custom)
    }

    private var wheel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SettingRow(symbol: SettingsTab.actions.symbol, title: "Run an action") {
                    ShortcutControl(title: "Run an action", action: .actions, error: $shortcutError)
                }
                if let shortcutError {
                    Label(shortcutError, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsSurface()
            ActionWheelCard(library: library, navigation: navigation, spare: spare, store: store).settingsSurface()
        }
    }

    private func runsWithBinding(_ target: ActionsNavigation.RunsWith) -> Binding<ActionRunsWith> {
        switch target {
        case .typed:
            Binding(get: { library.library.typed }, set: { library.setTyped($0) })
        case .action(let id):
            Binding(get: { library.action(id)?.runsWith ?? .sameAsFix }, set: { value in library.update(id) { $0.runsWith = value } })
        }
    }

    /// What back says it returns to.
    private func parentTitle(_ target: ActionsNavigation.RunsWith) -> String {
        switch target {
        case .typed: "Actions"
        case .action(let id): library.action(id)?.title ?? "Actions"
        }
    }
}
