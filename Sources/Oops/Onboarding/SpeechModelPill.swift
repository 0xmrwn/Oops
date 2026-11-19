import OopsCore
import SwiftUI

/// The speech model's download in the window's top trailing corner, where Settings puts its Update pill. It opens
/// wide once to say what it fetches, then stays as a ring and a percentage behind every step. Clicking it shows the
/// model, the language first run inferred, and the ways out: pause, or an OpenAI key in place of the download.
struct SpeechModelPill: View {
    let speech: OnboardingSpeechModel
    let useOpenAIKey: () -> Void
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                mark.frame(width: 16, height: 16)
                if speech.announcing { Text("Downloading \(speech.model.name) · \(speech.size)").transition(.opacity) }
                Text(status).monospacedDigit().contentTransition(.numericText())
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2)
        }
        .buttonStyle(.glass).buttonBorderShape(.capsule)
        .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.2), value: speech.announcing)
        .animation(.easeOut(duration: 0.2), value: speech.phase)
        .accessibilityLabel("Speech model")
        .accessibilityValue(spoken)
        .popover(isPresented: $open, arrowEdge: .bottom) { details }
        .onChange(of: speech.phase == .ready, initial: true) { _, ready in if ready { speech.settle() } }
    }

    @ViewBuilder private var mark: some View {
        switch speech.phase {
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
        case .paused: Image(systemName: "pause.fill").font(.system(size: 11))
        case .ready: Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
        case .downloading, .verifying:
            ZStack {
                Circle().stroke(.white.opacity(0.28), lineWidth: 2.5)
                Circle().trim(from: 0, to: speech.fraction).stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(1.25)
        }
    }

    private var status: String {
        switch speech.phase {
        case .downloading(let fraction): "\(Int((fraction * 100).rounded(.down)))%"
        case .verifying: "Checking"
        case .paused: "Paused"
        case .failed: "Retry"
        case .ready: "Ready"
        }
    }

    private var spoken: String {
        switch speech.phase {
        case .downloading: "Downloading \(speech.model.name), \(status)"
        case .verifying: "Checking \(speech.model.name)"
        case .paused: "Download paused"
        case .failed(let message): message
        case .ready: "\(speech.model.name) is ready"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(speech.model.name).fontWeight(.semibold)
                Spacer(minLength: 16)
                Text(speech.size).foregroundStyle(.secondary)
            }
            if case .failed(let message) = speech.phase {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ProgressView(value: speech.fraction).tint(.primary).accessibilityLabel("Download")
            }
            HStack {
                Text("Language")
                Spacer(minLength: 16)
                GlassMenu(title: "Language", choices: speech.languages,
                          selection: Binding(get: { speech.language }, set: { speech.choose(language: $0) }))
            }
            HStack(spacing: 8) {
                switch speech.phase {
                case .downloading, .verifying: Button("Pause") { speech.pause() }
                case .paused: Button("Resume") { speech.resume() }
                case .failed: Button("Retry") { speech.resume() }
                case .ready: EmptyView()
                }
                Button("Use an OpenAI key") { open = false; useOpenAIKey() }
            }
            .buttonStyle(.settingsGlass)
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 300)
    }
}
