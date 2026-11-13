import AppKit
import OopsCore
import SwiftUI

/// What the dictation drop says: a recording, its transcription, or why nothing was written.
enum DictationDropState: Equatable, Sendable {
    case recording
    case transcribing
    /// The microphone was just allowed, at a press that recorded nothing.
    case ready
    /// The transcript is in the field, as heard.
    case written
    /// The transcript is being rewritten by the cleanup model.
    case cleaningUp
    case failed(DictationFailure)
    /// No text field had focus: the transcript is kept, and the drop's one action copies it.
    case kept
    /// The kept transcript is on the clipboard.
    case copied

    var symbol: String {
        switch self {
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .ready: "mic"
        case .written: "checkmark"
        case .cleaningUp: "wand.and.sparkles"
        case .failed: "exclamationmark.triangle.fill"
        case .kept: "text.cursor"
        case .copied: "checkmark"
        }
    }

    var text: String {
        switch self {
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .ready: "Ready, press again"
        case .written: "Written"
        case .cleaningUp: "Cleaning up"
        case .failed(let failure): failure.message
        case .kept: "No text field"
        case .copied: "Copied"
        }
    }
}

/// Why a dictation wrote nothing, when that is worth saying.
enum DictationFailure: Equatable, Sendable {
    /// No model path, or no file at it.
    case noModel
    /// Microphone access denied.
    case microphoneAccess
    /// No input device, or it failed to start.
    case noMicrophone
    /// A build without the speech engine.
    case notInBuild
    /// The engine failed to load the model or to transcribe.
    case transcription
    /// A password or code field.
    case secureField
    /// An app dictation never writes in: a password manager.
    case appDenied
    /// An app turned off in Settings.
    case turnedOff
    /// The insert was refused for another reason.
    case cannotWrite
    /// The cleanup model failed, took too long or answered nothing: the text stays as heard.
    case cleanup
    /// The field no longer reads what dictation wrote, so its cleanup replaced nothing.
    case textChanged

    var message: String {
        switch self {
        case .noModel: "No speech model"
        case .microphoneAccess: "Microphone access is off"
        case .noMicrophone: "No microphone"
        case .notInBuild: "Dictation isn’t in this build"
        case .transcription: "Couldn’t transcribe"
        case .secureField: "Can’t write in a password field"
        case .appDenied: "Can’t write in this app"
        case .turnedOff: "Turned off in this app"
        case .cannotWrite: "Can’t write here"
        case .cleanup: "Couldn’t clean up"
        case .textChanged: "Text changed, nothing replaced"
        }
    }
}

/// Something the drop offers to do beside what it says: one at most, pressed in the drop's trailing cap.
struct DropAction {
    /// The button's SF Symbol.
    let symbol: String
    /// What it does, for its tooltip and assistive tech.
    let label: String
    let perform: @MainActor () -> Void
}

/// The drop as a dictation sees it: claimed for the recording, told each state, and let go.
@MainActor protocol DictationDrop: AnyObject {
    /// Takes the drop for dictation; false while another feature holds it. `busy` keeps it held while the
    /// dictation is at work and its drop has yet to show.
    func claim(busy: @escaping () -> Bool) -> Bool
    /// Shows `state`, with `action` to press beside it or none; a state that isn't work under way (a failure, the
    /// word that the microphone is ready, a written or kept transcript and its copy) leaves by itself after a while.
    func show(_ state: DictationDropState, action: DropAction?)
    /// The drop leaves.
    func leave()
    /// The words so far while a dictation streams, shown where Settings' Live words says (in the drop, or at the
    /// caret through the highlight overlay, falling back to the drop where the overlay can't place them); nil, or
    /// words with nothing in them, takes them away. The session clears them before it writes and as a dictation ends.
    func showWords(_ words: LiveWords?)
}

extension DictationDrop {
    /// Shows `state` with nothing to press.
    func show(_ state: DictationDropState) { show(state, action: nil) }
    /// A drop that shows no words (test fakes) needs nothing.
    func showWords(_ words: LiveWords?) {}
}

extension DictationLiveWordsPlace {
    /// Where Settings keeps the place, by raw value.
    static let key = "DictationLiveWords"
    /// The place as saved, the drop until one is chosen.
    static var saved: DictationLiveWordsPlace { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .drop }
}

extension DictationDropPosition {
    /// Where Settings keeps the position, by raw value.
    static let key = "DictationDropPosition"
    /// The position as saved, by the text field until one is chosen.
    static var saved: DictationDropPosition { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .anchored }
}

/// What the dictation drop shows, apart from Fix's model.
@MainActor @Observable final class DictationDropModel {
    var state = DictationDropState.recording
    /// What the drop offers to press with this state; nil has nothing, and the drop lets clicks through.
    var action: DropAction?
    /// Read as the drop comes up, so a change in Settings applies to the next dictation.
    var visualizer = DictationVisualizer.standard
    /// The recording's loudness, which the visualizer follows; nil where nothing records.
    let loudness: DictationLoudnessFeed?
    /// The kept transcript's copy button was pressed; its icon turns into a check.
    var copied = false
    /// The words so far while a dictation streams, when they show in the drop; nil shows none.
    var words: LiveWords?
    /// Debug only: the words take the state word's place in the capsule, instead of a line beside it.
    let inlineWords = DebugFlags.liveWordsLayout == "inline"
    init(loudness: DictationLoudnessFeed? = nil) { self.loudness = loudness }
}

/// The dictation drop in the panel the features share (`DropOwner`), placed by the focused field when its
/// geometry can be read, or at the neutral spot.
@MainActor final class DictationDropOwner: DictationDrop {
    private let owner: DropOwner
    private let model: DictationDropModel
    /// The focused field's geometry, read without capturing a draft.
    private let locate: @MainActor () async -> CapsulePlacement.Geometry?
    /// The drop is on its way up, once its spot is known.
    private var locating: Task<Void, Never>?
    private var panel: CapsulePanel { owner.panel }
    /// The field's geometry as the drop came up, where words at the caret go.
    private var geometry: CapsulePlacement.Geometry?
    /// Live words' place, read as the recording shows; the latest words, kept until the drop's spot is known; and
    /// whether this dictation's target was logged.
    private var place = DictationLiveWordsPlace.drop, words: LiveWords?, logged = false
    /// The app in front as the recording started: words at the caret belong to its field.
    private var host: pid_t?

    init(owner: DropOwner, loudness: DictationLoudnessFeed? = nil, locate: @escaping @MainActor () async -> CapsulePlacement.Geometry?) {
        self.owner = owner; self.locate = locate; model = DictationDropModel(loudness: loudness)
    }

    func claim(busy: @escaping () -> Bool) -> Bool {
        // Room for the line of live words beside the capsule, so placement keeps it off the text too.
        let size = model.inlineWords ? CapsulePanel.standard : CGSize(width: 280, height: CapsulePanel.standard.height + DictationLivePreview.room)
        return owner.claim(.dictate, busy: busy, size: size) { [model, capsule = owner.panel.model] in
            AnyView(DictationDropView(model: model, capsule: capsule))
        }
    }

    func show(_ state: DictationDropState, action: DropAction?) {
        // As Fix's copy does: the button's icon becomes a check, then the drop says so and leaves.
        if state == .copied, model.state == .kept, panel.isShown {
            model.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, model.copied, model.state == .kept else { return }
                model.state = .copied; model.action = nil
                panel.present(); settle()
            }
            return
        }
        model.copied = false
        model.state = state
        model.action = action
        if state == .recording {
            // A new dictation: none of the last one's words, and the place as Settings says now.
            showWords(nil)
            place = .saved; logged = false; host = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if locating != nil { return }
        // Already up: it keeps its spot, and a new state stops a failure's timed exit.
        if panel.isShown { panel.present(); settle(); return }
        model.visualizer = .stored()
        locating = Task { [weak self] in
            let geometry = await self?.locate()
            guard let self, !Task.isCancelled else { return }
            locating = nil
            self.geometry = geometry
            // Read at each dictation, so a change in Settings applies to the next one.
            let position = DictationDropPosition.saved.resolved(hasAnchor: geometry?.element != nil)
            panel.present(geometry: geometry, fixed: position == .anchored ? nil : position)
            settle()
            if let words { route(words) }
        }
    }

    func leave() {
        locating?.cancel(); locating = nil
        showWords(nil)
        geometry = nil
        panel.hide()
    }

    func showWords(_ words: LiveWords?) {
        guard let words, !words.isEmpty else {
            self.words = nil; model.words = nil
            return owner.highlight.clearWords()
        }
        self.words = words
        // Until the drop's spot is known, the newest words wait for it.
        if locating == nil, panel.isShown { route(words) }
    }

    /// At the caret when Settings and the field allow it, and while the field's app is still in front; in the drop
    /// otherwise.
    private func route(_ words: LiveWords) {
        var target = LiveWordsAnchor.target(place, geometry: geometry)
        if case .caret = target, NSWorkspace.shared.frontmostApplication?.processIdentifier != host { target = .drop }
        if case let .caret(caret, width) = target {
            model.words = nil
            owner.highlight.showWords(words, at: caret, width: width)
        } else {
            owner.highlight.clearWords()
            model.words = words
        }
        guard !logged else { return }
        logged = true
        let name = if case .caret = target { "caret" } else { place == .text ? "fallback" : "drop" }
        DictationSession.log.notice("live target=\(name, privacy: .public)")
    }

    /// A failure, or the word that the microphone is ready, stays as long as Fix's results do, then leaves; a
    /// kept transcript stays as long as Fix's failures, for its button, and the word that it was copied briefly.
    private func settle() {
        switch model.state {
        case .failed, .ready, .written: panel.hide(after: ResultTiming.seconds)
        case .kept: panel.hide(after: 8)
        case .copied: panel.hide(after: 0.9)
        case .recording, .transcribing, .cleaningUp: break
        }
    }
}
