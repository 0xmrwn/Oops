import OopsCore
import SwiftUI

/// What the dictation drop says: a recording, its transcription, or why nothing was written.
enum DictationDropState: Equatable, Sendable {
    case recording
    case transcribing
    /// The microphone was just allowed, at a press that recorded nothing.
    case ready
    case failed(DictationFailure)

    var symbol: String {
        switch self {
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .ready: "mic"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var text: String {
        switch self {
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .ready: "Ready, press again"
        case .failed(let failure): failure.message
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
    /// The insert was refused.
    case cannotWrite

    var message: String {
        switch self {
        case .noModel: "No speech model"
        case .microphoneAccess: "Microphone access is off"
        case .noMicrophone: "No microphone"
        case .notInBuild: "Dictation isn’t in this build"
        case .transcription: "Couldn’t transcribe"
        case .cannotWrite: "Can’t write here"
        }
    }
}

/// The drop as a dictation sees it: claimed for the recording, told each state, and let go.
@MainActor protocol DictationDrop: AnyObject {
    /// Takes the drop for dictation; false while another feature holds it. `busy` keeps it held while the
    /// dictation is at work and its drop has yet to show.
    func claim(busy: @escaping () -> Bool) -> Bool
    /// Shows `state`; a failure, and the word that the microphone is ready, leave by themselves after the
    /// time results stay.
    func show(_ state: DictationDropState)
    /// The drop leaves.
    func leave()
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
    /// Read as the drop comes up, so a change in Settings applies to the next dictation.
    var visualizer = DictationVisualizer.standard
    /// The recording's loudness, which the visualizer follows; nil where nothing records.
    let loudness: DictationLoudnessFeed?
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

    init(owner: DropOwner, loudness: DictationLoudnessFeed? = nil, locate: @escaping @MainActor () async -> CapsulePlacement.Geometry?) {
        self.owner = owner; self.locate = locate; model = DictationDropModel(loudness: loudness)
    }

    func claim(busy: @escaping () -> Bool) -> Bool {
        owner.claim(.dictate, busy: busy) { [model, capsule = owner.panel.model] in AnyView(DictationDropView(model: model, capsule: capsule)) }
    }

    func show(_ state: DictationDropState) {
        model.state = state
        if locating != nil { return }
        // Already up: it keeps its spot, and a new state stops a failure's timed exit.
        if panel.isShown { panel.present(); settle(); return }
        model.visualizer = .stored()
        locating = Task { [weak self] in
            let geometry = await self?.locate()
            guard let self, !Task.isCancelled else { return }
            locating = nil
            // Read at each dictation, so a change in Settings applies to the next one.
            let position = DictationDropPosition.saved.resolved(hasAnchor: geometry?.element != nil)
            panel.present(geometry: geometry, fixed: position == .anchored ? nil : position)
            settle()
        }
    }

    func leave() {
        locating?.cancel(); locating = nil
        panel.hide()
    }

    /// A failure, or the word that the microphone is ready, stays as long as Fix's results do, then leaves.
    private func settle() {
        switch model.state {
        case .failed, .ready: panel.hide(after: ResultTiming.seconds)
        case .recording, .transcribing: break
        }
    }
}
