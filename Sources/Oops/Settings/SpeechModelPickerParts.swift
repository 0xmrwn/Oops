import AppKit
import OopsCore
import SwiftUI

/// The maker's mark, monochrome on the glass like the provider marks; a waveform for a community fine-tune.
struct SpeechModelMark: View {
    let maker: SpeechModelMaker?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let maker {
                Image(Self.asset(maker), bundle: .main).renderingMode(.template).resizable().interpolation(.high)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "waveform").font(.system(size: size * 0.72, weight: .medium)).secondaryText()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func asset(_ maker: SpeechModelMaker) -> String {
        switch maker {
        case .nvidia: "NvidiaMark"
        case .openAI: "OpenAIMark"
        case .cohere: "CohereMark"
        case .qwen: "QwenMark"
        case .alibaba: "AlibabaMark"
        case .ibm: "IBMMark"
        }
    }
}

/// The model in use. In the list it is a capsule the size of the buttons it sits among, outlined since it does
/// nothing; a card or strip already carries the outline.
struct SpeechModelInUse: View {
    var outlined = false

    var body: some View {
        Label("In use", systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold)).labelStyle(TightLabel())
            .frame(maxWidth: .infinity, minHeight: 30)
            .overlay { if outlined { Capsule().strokeBorder(.primary.opacity(0.85), lineWidth: 1.5) } }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

/// One of a language's picks: the maker, the name, why it was picked, three facts and what to do with it.
struct SpeechModelCard: View {
    let choice: SpeechModelChoice
    let picks: SpeechModelPicks
    let actions: SpeechModelActions

    var body: some View {
        let model = choice.model, inUse = actions.inUse(model)
        VStack(alignment: .leading, spacing: 0) {
            SpeechModelMark(maker: model.maker, size: 30)
            Text(model.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                .frame(height: 40, alignment: .topLeading)
                .padding(.top, 18).padding(.bottom, 10)
            tag
            VStack(alignment: .leading, spacing: 11) {
                SpeechModelFact(strong: picks.shortestWait == model.id) { SpeechModelWaitBars(wait: model.wait); Text(model.wait.label) }
                if let accuracy = model.accuracy {
                    SpeechModelFact(strong: picks.mostAccurate == model.id) { Image(systemName: "scope"); Text(SpeechModelRow.percent(accuracy)) }
                }
                SpeechModelFact(strong: picks.mostLanguages == model.id) { Image(systemName: "globe"); Text(model.languageSummary) }
            }
            .padding(.top, 22).padding(.bottom, 22)
            Spacer(minLength: 0)
            SpeechModelAction(model: model, actions: actions, wide: true)
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)
        .frame(maxWidth: 190, minHeight: 318, alignment: .topLeading)
        .background(.primary.opacity(inUse ? 0.1 : 0.06), in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(inUse ? 0.9 : 0.1), lineWidth: inUse ? 1.5 : 0.5) }
        .animation(.easeOut(duration: 0.2), value: inUse)
        .contentShape(.rect(cornerRadius: 22))
        .speechModelMenu(model, actions: actions)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.name)
    }

    private var tag: some View {
        let (symbol, title) = switch choice.recommendation {
        case .recommended: ("star.fill", "Recommended")
        case .mostAccurate: ("scope", "Most accurate")
        case .fastest: ("bolt.fill", "Fastest")
        case .vocabulary: ("character.book.closed", "Vocabulary")
        }
        return Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 9).frame(height: 22)
            .background(.primary.opacity(0.16), in: .capsule)
            // The one tag whose word needs saying.
            .help(choice.recommendation == .vocabulary ? SpeechModelHelp.vocabulary : "")
    }
}

/// A fact with its symbol; the one a pick leads on reads stronger.
struct SpeechModelFact<Content: View>: View {
    let strong: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 7) { content }
            .font(.system(size: 13.5, weight: strong ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(.primary.opacity(strong ? 1 : 0.62))
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }
}

/// The wait as three rising bars, the more filled the sooner the words arrive.
struct SpeechModelWaitBars: View {
    let wait: SpeechModelWait

    var body: some View {
        Image(systemName: "chart.bar.fill", variableValue: Double(wait.rawValue) / 3)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// A model in the full list.
struct SpeechModelRow: View {
    static let wait: CGFloat = 62, accuracy: CGFloat = 56, action: CGFloat = SpeechModelAction.width + 40
    let model: SpeechModel
    let picks: SpeechModelPicks
    /// Wait and accuracy, for a model that takes the picker's language.
    let figures: Bool
    let actions: SpeechModelActions

    var body: some View {
        Self.layout(mark: model.maker, name: model.name, wait: figures ? model.wait : nil,
                    accuracy: figures ? model.accuracy : nil, inUse: actions.inUse(model)) {
            Label(model.languageSummary, systemImage: "globe")
            if model.vocabularyUse == .prompt {
                Label("Vocabulary", systemImage: "character.book.closed").help(SpeechModelHelp.vocabulary)
            }
        } action: {
            SpeechModelAction(model: model, actions: actions, wide: false)
        }
        .speechModelMenu(model, actions: actions)
    }

    static func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) + " %" }

    // swiftlint:disable:next function_parameter_count
    static func layout(mark: SpeechModelMaker?, name: String, wait: SpeechModelWait?, accuracy: Double?, inUse: Bool,
                       @ViewBuilder details: () -> some View, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            SpeechModelMark(maker: mark, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.semibold).lineLimit(1)
                HStack(spacing: 9) { details() }.font(.caption).labelStyle(TightLabel()).secondaryText().lineLimit(1)
            }
            Spacer(minLength: 8)
            Group {
                if let wait { SpeechModelFact(strong: false) { SpeechModelWaitBars(wait: wait); Text(wait.label) } }
            }
            .frame(width: Self.wait, alignment: .leading)
            Text(accuracy.map(percent) ?? "").font(.system(size: 13.5)).monospacedDigit().secondaryText()
                .frame(width: Self.accuracy, alignment: .leading)
            HStack(spacing: 6) { action() }.frame(width: Self.action, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(minHeight: 56)
        .background(.primary.opacity(inUse ? 0.1 : 0), in: .rect(cornerRadius: 14))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

/// The models a provider runs instead of this Mac: OpenAI's live transcription, used with an OpenAI API key.
/// Without one, its button leads to where the key is entered.
struct SpeechModelOnline: View {
    /// Nil until an OpenAI key is set up.
    let reference: VoiceModelReference?
    let actions: SpeechModelActions
    let addKey: () -> Void

    var body: some View {
        let inUse = reference != nil && actions.current() == reference
        VStack(alignment: .leading, spacing: 12) {
            SpeechModelRow.layout(mark: .openAI, name: DictateModelOption.openAIName, wait: .live, accuracy: nil, inUse: inUse) {
                Label("OpenAI", systemImage: "cloud")
                Label("Any language", systemImage: "globe")
            } action: {
                Group {
                    if inUse {
                        SpeechModelInUse(outlined: true)
                    } else if let reference {
                        button("Use") { actions.use(reference) }
                    } else {
                        button("Add key", action: addKey)
                    }
                }
                .frame(width: SpeechModelAction.width)
            }
            // What changes when the model is not on this Mac; a fact, said once.
            Label("Your voice is sent to the provider, and its use is billed to your key.", systemImage: "arrow.up.forward.circle")
                .font(.caption).labelStyle(TightLabel()).secondaryText().padding(.horizontal, 8)
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).fontWeight(.medium).frame(maxWidth: .infinity) }
            .buttonStyle(.settingsGlass).controlSize(.large)
    }
}

/// The words the picker explains on hover: the ones a first reader wouldn't know.
enum SpeechModelHelp {
    static let accuracy = "Words it gets right out of 100 on a public test. The tests differ between models."
    static let vocabulary = "Follows your vocabulary: the names and unusual words you list under Dictate → Vocabulary"
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// What a model's card or row does: its size to download it (which then selects it), the download under way with
/// its cancel, Use beside Delete once it is installed, or In use. In the list every main control has one width.
struct SpeechModelAction: View {
    static let width: CGFloat = 104
    let model: SpeechModel
    let actions: SpeechModelActions
    let wide: Bool

    var body: some View {
        let state = actions.state(model)
        HStack(spacing: 6) {
            switch state {
            case .installed where actions.inUse(model):
                main { SpeechModelInUse(outlined: !wide) }
            case .installed:
                small("trash", "Delete \(model.name)", help: "Delete from this Mac and free \(model.downloadSize)") { actions.delete(model) }
                main { button("Use", symbol: nil) { actions.use(.local(model.id)) } }
            case .notInstalled:
                main { button(model.downloadSize, symbol: "arrow.down") { actions.download(model) } }
                    .accessibilityLabel("Download \(model.name), \(model.downloadSize)")
            case .failed(let message):
                main { button("Retry", symbol: "exclamationmark.triangle") { actions.download(model) } }
                    .help(message).accessibilityLabel("\(message) Retry downloading \(model.name)")
            case .downloading(let fraction):
                small("xmark", "Cancel download of \(model.name)", help: "Cancel") { actions.cancel(model) }
                main { progress(fraction, "\(Int((fraction * 100).rounded(.down))) %") }
                    .accessibilityLabel("Downloading \(model.name), \(Int(fraction * 100)) percent")
            case .verifying:
                main { progress(1, "Checking") }.accessibilityLabel("Checking \(model.name)")
            }
        }
        .frame(height: 32)
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private func main(@ViewBuilder _ content: () -> some View) -> some View {
        content().frame(width: wide ? nil : Self.width).frame(maxWidth: wide ? .infinity : nil)
    }

    private func small(_ symbol: String, _ label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 10, height: 14)
        }
        .buttonStyle(.settingsGlass).buttonBorderShape(.circle).controlSize(.large)
        .help(help).accessibilityLabel(label)
    }

    private func button(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).fontWeight(.medium).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsGlass).controlSize(.large)
    }

    /// The button's own capsule, filling as the download comes in.
    private func progress(_ fraction: Double, _ text: String) -> some View {
        Text(text).font(.callout.weight(.medium)).monospacedDigit().contentTransition(.numericText())
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Color.primary.opacity(0.09)
                        Color.primary.opacity(0.2).frame(width: box.size.width * fraction)
                    }
                }
            }
            .clipShape(.capsule)
            .glassEdge(Capsule())
            .animation(.linear(duration: 0.2), value: fraction)
    }
}

extension View {
    /// A model's page, its licence and, for an installed one that isn't in use, Delete: on a secondary click,
    /// away from the card.
    func speechModelMenu(_ model: SpeechModel, actions: SpeechModelActions) -> some View {
        contextMenu {
            if let page = model.page { Button("Model page") { NSWorkspace.shared.open(page) } }
            if model.license.isRecorded {
                Button("License: \(model.license.name)") { if let url = model.license.url { NSWorkspace.shared.open(url) } }
                    .disabled(model.license.url == nil)
            }
            if actions.state(model) == .installed, !actions.inUse(model) {
                Button("Delete", role: .destructive) { actions.delete(model) }
            }
        }
        // The same on the element itself: VoiceOver and automation have no secondary click.
        .accessibilityActions {
            if actions.state(model) == .installed, !actions.inUse(model) { Button("Delete") { actions.delete(model) } }
        }
    }
}
