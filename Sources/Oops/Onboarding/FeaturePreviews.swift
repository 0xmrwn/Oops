import OopsCore
import SwiftUI

/// The choice step's previews, one per row: each feature at work on the row's glass, drawn by the app's own
/// parts. Fix's is Hello's typed draft and its real correction, lit as the Try page lights one; Dictate's is the
/// drop's own voice, then the words the speech engine returned for Hello's clip, landing whole as they do on release.
@MainActor @Observable final class FeaturePreviews {
    let draft = HelloWindowState(HelloDraft.typed)
    let voice: DictationDropModel
    /// The voice is speaking; its words land once it stops.
    private(set) var speaking = false
    private(set) var heard = ""
    @ObservationIgnored private let loudness = DictationLoudnessFeed()

    init() {
        voice = DictationDropModel(loudness: loudness)
        voice.state = .recording
        rest()
    }

    /// Still: what each feature leaves behind.
    func rest() {
        loudness.stop()
        draft.typed = nil; draft.corrected = true; draft.flash = 0
        speaking = false; heard = HelloDraft.spoken
    }

    /// Both previews, over and over, each at its own pace so the rows never move in step.
    func play() async {
        defer { rest() }
        async let fixing: Void = fix()
        async let dictating: Void = dictate()
        _ = await (fixing, dictating)
    }

    /// The voice alone, for as long as it is shown: the new-feature card's.
    func listen() async {
        let began = CACurrentMediaTime()
        loudness.start { HelloVoice.level(at: CACurrentMediaTime() - began) }
        speaking = true
        while await wait(60) {}
        rest()
    }

    private func fix() async {
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.3)) { draft.corrected = false }
            guard await wait(1.7) else { return }
            withAnimation(.easeInOut(duration: 0.12)) { draft.corrected = true }
            withAnimation(.easeOut(duration: 0.12)) { draft.flash = 1 }
            withAnimation(.easeIn(duration: ResultTiming.flash * 0.6).delay(ResultTiming.flash * 0.4)) { draft.flash = 0 }
            guard await wait(3.1) else { return }
        }
    }

    private func dictate() async {
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.3)) { heard = "" }
            guard await wait(0.5) else { return }
            let began = CACurrentMediaTime()
            loudness.start { HelloVoice.level(at: CACurrentMediaTime() - began) }
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { speaking = true }
            guard await wait(2.1) else { return }
            loudness.stop()
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { speaking = false; heard = HelloDraft.spoken }
            guard await wait(2.9) else { return }
        }
    }

    private func wait(_ seconds: Double) async -> Bool {
        (try? await Task.sleep(for: .seconds(seconds))) != nil
    }
}

/// Fix at work, in the row's own ink on its glass: Hello's draft, then its correction with the changed words lit.
struct FixPreview: View {
    let previews: FeaturePreviews

    var body: some View {
        HelloDraftText(state: previews.draft, size: 15, color: .white, chip: .white, highlight: .white.opacity(0.3)).fontWeight(.medium).lineLimit(1)
            .shadow(color: .black.opacity(0.35), radius: 3)
    }
}

/// Dictate at work: the drop's voice, then what it heard.
struct DictatePreview: View {
    let previews: FeaturePreviews

    var body: some View {
        ZStack(alignment: .leading) {
            if previews.speaking {
                VoicePreview(model: previews.voice, dark: true, scale: 0.9)
                    .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
            } else {
                Text(verbatim: previews.heard).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The dictation drop's own voice, following an acted loudness.
struct VoicePreview: View {
    let model: DictationDropModel
    let dark: Bool
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = DictationVisualizerView.size(.recording), feed = model.loudness
        // Hex reads the level as it draws; the other kinds are handed it.
        let live: (@MainActor () -> Float)? = model.visualizer == .hex ? { @MainActor in feed?.level ?? 0 } : nil
        DictationVisualizerView(kind: model.visualizer, phase: .recording, loudness: live == nil ? feed?.level ?? 0 : 0,
                                live: live, isDark: dark, reduceMotion: reduceMotion)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
    }
}
