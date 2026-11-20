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

/// Which model page Dictate shows; a model row opens it by setting its target.
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

/// Dictate → Speech model: the language's picks as cards, every model on this Mac as a list, or the ones a
/// provider runs online. A download selects its model once it is installed, whether or not the page is still open.
struct SpeechModelPage: View {
    let target: SpeechModelPickerTarget
    let store: ProviderStore
    let local: LocalModels
    let back: () -> Void
    @State private var shown = Shown.picks

    private enum Shown: Hashable { case picks, all, online }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let picks = SpeechModelPicks(language: target.language, models: local.models)
        VStack(alignment: .leading, spacing: 20) {
            DrillHeader(title: "Speech model", parent: "Dictate", back: back) {
                Image(systemName: "waveform").font(.system(size: 18, weight: .medium))
            } accessory: {
                Label(DictateModelCard.name(target.language), systemImage: "globe")
                    .font(.system(size: 13, weight: .medium)).labelStyle(.titleAndIcon).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.primary.opacity(0.16), in: .capsule)
                    .overlay { Capsule().strokeBorder(.primary.opacity(0.22), lineWidth: 0.5) }
                    .accessibilityLabel("For \(DictateModelCard.name(target.language))")
                // A keyboard switches to a model on this Mac, so its page has no Online.
                GlassChoice(title: "Models", choices: [(.picks, "Picks"), (.all, "All")] + (target.offersOpenAI ? [(Shown.online, "Online")] : []),
                            selection: $shown)
                    // On the page itself, glass draws over what isn't its own content: the pill blurred the label
                    // it sits behind. A glass that shows nothing makes the labels its content, as a card does.
                    .glassEffect(.identity, in: .capsule)
            }
            Group {
                switch shown {
                // Rows carry an inset of their own, for the highlight of the one in use.
                case .all: SpeechModelList(picks: picks, actions: actions).padding(.horizontal, -8).transition(.opacity)
                // The key is entered under Providers; this page is still here on the way back.
                case .online: SpeechModelOnline(reference: store.openAIDictateReference, actions: actions, addKey: store.setUpOpenAITranscription)
                    .padding(.horizontal, -8).transition(.opacity)
                case .picks: cards(picks).transition(.opacity)
                }
            }
            .settingsSurface()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown)
        .task { await local.refresh() }
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
                // One tip for both columns: they sit too close for one each.
                InfoTip("Wait and accuracy", SpeechModelHelp.wait + " " + SpeechModelHelp.accuracy)
                Text("Wait").frame(width: SpeechModelRow.wait, alignment: .leading)
                Text("Accuracy").frame(width: SpeechModelRow.accuracy, alignment: .leading)
                Color.clear.frame(width: SpeechModelRow.action, height: 1)
            }
            .font(.caption).secondaryText().padding(.horizontal, 8).padding(.bottom, 4)
            let listed = picks.picks.map(\.model) + picks.others
            ForEach(Array(listed.enumerated()), id: \.element.id) { index, model in
                if index > 0 { SettingsDivider().padding(.leading, 42) }
                SpeechModelRow(model: model, picks: picks, figures: true, actions: actions)
            }
            if !picks.elsewhere.isEmpty {
                Label("Other languages", systemImage: "globe").font(.caption).secondaryText()
                    .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
                ForEach(Array(picks.elsewhere.enumerated()), id: \.element.id) { index, model in
                    if index > 0 { SettingsDivider().padding(.leading, 42) }
                    SpeechModelRow(model: model, picks: picks, figures: false, actions: actions)
                }
            }
        }
    }
}
