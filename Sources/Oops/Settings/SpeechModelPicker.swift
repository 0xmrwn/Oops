import OopsCore
import SwiftUI

/// What the speech model picker chooses for: Dictate's model, or the one a keyboard switches to.
struct SpeechModelPickerTarget {
    /// Which choice this is, so a download knows whether it is still the one wanted here.
    let id: String
    /// The language whose picks it shows.
    let language: String
    /// OpenAI's live transcription is Dictate's to choose; a keyboard maps to a model on this Mac.
    var offersOpenAI = true
    let current: () -> VoiceModelReference?
    let choose: (VoiceModelReference) -> Void
}

/// The picker Settings shows over itself; a model row opens it by setting its target.
@Observable @MainActor final class SpeechModelPicker {
    static let shared = SpeechModelPicker()
    var target: SpeechModelPickerTarget?
    /// The model each target is waiting on: the last download started for it, until another choice is made there.
    /// A download that is no longer the one wanted still installs, without taking the selection.
    @ObservationIgnored private var awaited: [String: String] = [:]

    func expect(_ model: String, for target: String) { awaited[target] = model }
    /// Whether `model`, just installed, is still what `target` waits on; asked once.
    func claims(_ model: String, for target: String) -> Bool {
        guard awaited[target] == model else { return false }
        awaited[target] = nil
        return true
    }
    /// A choice made by hand stands over a download still coming in.
    func chose(for target: String) { awaited[target] = nil }
}

/// Settings' top layer: the picker over a dimmed window, closed by Escape, its button or a click outside.
struct SpeechModelPickerOverlay: View {
    let picker: SpeechModelPicker
    let store: ProviderStore
    var local = LocalModels.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let target = picker.target {
                Color.black.opacity(scheme == .dark ? 0.45 : 0.22)
                    .contentShape(Rectangle()).onTapGesture { picker.target = nil }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                SpeechModelPickerPanel(target: target, store: store, local: local) { picker.target = nil }
                    .padding(.horizontal, 12).padding(.top, 58)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.975, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.12), value: picker.target != nil)
    }
}

/// The picker: the language's picks as cards, every model on this Mac as a list, or the ones a provider runs
/// online. A download selects its model once it is installed, whether or not the picker is still open.
struct SpeechModelPickerPanel: View {
    let target: SpeechModelPickerTarget
    let store: ProviderStore
    let local: LocalModels
    let close: () -> Void
    @State private var shown = Shown.picks

    private enum Shown: Hashable { case picks, all, online }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let picks = SpeechModelPicks(language: target.language, models: local.models)
        VStack(alignment: .leading, spacing: 18) {
            header
            switch shown {
            case .all:
                // The scroller runs in the panel's own margin, clear of the buttons.
                ScrollView { SpeechModelList(picks: picks, actions: actions).padding(.trailing, 14) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: 536)
                    .padding(.trailing, -14)
                    .focusEffectDisabled()
                    .transition(.opacity)
            case .online:
                SpeechModelOnline(reference: store.openAIDictateReference, actions: actions) {
                    close()
                    store.setUpOpenAITranscription()
                }
                .transition(.opacity)
            case .picks:
                cards(picks).transition(.opacity)
            }
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 16)
        // The cards' own height, not the window's.
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .glassEdge(RoundedRectangle(cornerRadius: 26), outside: true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown)
        .task { await local.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speech model")
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Speech model").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Label(DictateModelCard.name(target.language), systemImage: "globe")
                .font(.system(size: 13, weight: .medium)).labelStyle(.titleAndIcon)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.primary.opacity(0.16), in: .capsule)
                .overlay { Capsule().strokeBorder(.primary.opacity(0.22), lineWidth: 0.5) }
                .accessibilityLabel("For \(DictateModelCard.name(target.language))")
            Spacer(minLength: 8)
            // A keyboard switches to a model on this Mac, so its picker has no Online.
            GlassChoice(title: "Models", choices: [(.picks, "Picks"), (.all, "All")] + (target.offersOpenAI ? [(Shown.online, "Online")] : []),
                        selection: $shown)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 8, height: 14)
            }
            .buttonStyle(.settingsGlass).buttonBorderShape(.circle).controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .help("Close").accessibilityLabel("Close")
        }
        .padding(.leading, 8)
    }

    private func cards(_ picks: SpeechModelPicks) -> some View {
        VStack(spacing: 14) {
            // The model in use when it is none of the picks: still first, so the choice is never out of sight.
            if let (name, maker) = used(), !picks.picks.contains(where: { .local($0.model.id) == target.current() }) {
                HStack(spacing: 12) {
                    SpeechModelMark(maker: maker, size: 22)
                    Text(name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 8)
                    SpeechModelInUse().fixedSize()
                }
                .padding(.horizontal, 16).frame(height: 54)
                .background(.primary.opacity(0.1), in: .rect(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.9), lineWidth: 1.5) }
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(picks.picks, id: \.model.id) { choice in
                    SpeechModelCard(choice: choice, picks: picks, actions: actions)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var actions: SpeechModelActions {
        SpeechModelActions(
            state: { local.state($0) },
            current: target.current,
            download: { model in
                let picker = SpeechModelPicker.shared, id = target.id, choose = target.choose
                picker.expect(model.id, for: id)
                local.download(model) { if picker.claims(model.id, for: id) { choose(.local(model.id)) } }
            },
            cancel: { local.cancel($0) },
            use: { SpeechModelPicker.shared.chose(for: target.id); target.choose($0) },
            delete: { model in Task { await store.deleteLocalModel(model, from: local) } })
    }

    /// The model in use, when it can be used: installed on this Mac, or OpenAI's with its key. A keyboard's mapping
    /// can outlive the model it names.
    private func used() -> (name: String, maker: SpeechModelMaker?)? {
        switch target.current() {
        case .local(let id)?:
            guard local.isInstalled(id), let model = SpeechModelCatalog.model(id: id) else { return nil }
            return (model.name, model.maker)
        case let reference? where reference == store.openAIDictateReference: return (DictateModelOption.openAIName, .openAI)
        default: return nil
        }
    }
}

/// What a card or row does with its model, and where the model stands.
struct SpeechModelActions {
    let state: (SpeechModel) -> LocalModels.State
    let current: () -> VoiceModelReference?
    let download: (SpeechModel) -> Void
    let cancel: (SpeechModel) -> Void
    let use: (VoiceModelReference) -> Void
    let delete: (SpeechModel) -> Void

    func inUse(_ model: SpeechModel) -> Bool { current() == .local(model.id) && state(model) == .installed }
}

/// Every model: the language's picks first, the others that take it, then the rest without figures, which
/// were measured in their own languages.
private struct SpeechModelList: View {
    let picks: SpeechModelPicks
    let actions: SpeechModelActions

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                Text("Wait").frame(width: SpeechModelRow.wait, alignment: .leading)
                Text("Accuracy").frame(width: SpeechModelRow.accuracy, alignment: .leading).help(SpeechModelHelp.accuracy)
                Color.clear.frame(width: SpeechModelRow.action, height: 1)
            }
            .font(.caption).secondaryText().padding(.horizontal, 8).padding(.bottom, 4)
            let listed = picks.picks.map(\.model) + picks.others
            ForEach(Array(listed.enumerated()), id: \.element.id) { index, model in
                if index > 0 { Divider().padding(.leading, 42) }
                SpeechModelRow(model: model, picks: picks, figures: true, actions: actions)
            }
            if !picks.elsewhere.isEmpty {
                Label("Other languages", systemImage: "globe").font(.caption).secondaryText()
                    .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
                ForEach(Array(picks.elsewhere.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { Divider().padding(.leading, 42) }
                    SpeechModelRow(model: model, picks: picks, figures: false, actions: actions)
                }
            }
        }
    }
}
