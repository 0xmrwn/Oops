import CTranscribe
import Foundation
import OopsCore

/// What one run passes beside the audio: the language hint and the vocabulary, in the C API's terms. A Parakeet bias
/// goes in as the run's vocabulary plus the Parakeet vocabulary extension (its boost and declared "sounds like"
/// spellings), which upstream's Swift wrapper leaves unbound; a Whisper or Qwen3-ASR list goes in as the context
/// prompt. Each is sent only where the loaded model says it takes it, so an empty or unsupported vocabulary sends
/// nothing. The library copies every string before `transcribe_run` returns.
struct RunOptions {
    let language: String?
    let bias: VocabularyBias?
    /// The extension only where the model accepts its kind; the terms alone still bias with the family's default boost.
    let biasExtension: Bool
    let prompt: String?

    init(language: String?, vocabulary: VocabularyDelivery?, model: OpaquePointer?) {
        self.language = language
        switch vocabulary {
        case let .parakeetBias(bias)? where !bias.terms.isEmpty && model.map { transcribe_model_supports($0, TRANSCRIBE_FEATURE_VOCABULARY) } == true:
            self.bias = bias
            biasExtension = transcribe_model_accepts_ext_kind(model, TRANSCRIBE_EXT_SLOT_RUN, TRANSCRIBE_EXT_KIND_PARAKEET_VOCABULARY)
            prompt = nil
        case let .prompt(text)? where !text.isEmpty && model.map { transcribe_model_supports($0, TRANSCRIBE_FEATURE_CONTEXT_PROMPT) } == true:
            bias = nil; biasExtension = false; prompt = text
        default:
            bias = nil; biasExtension = false; prompt = nil
        }
    }

    /// Whether the run needs params at all.
    var isNeeded: Bool { language != nil || bias != nil || prompt != nil }

    /// `body` with params pointing at this run's options, valid only inside it.
    func withParams<Result>(_ body: (UnsafePointer<transcribe_run_params>) -> Result) -> Result {
        let terms = CStrings(bias?.terms ?? []), spellings = CStrings(bias?.soundsLike.map(\.spelling) ?? [])
        let owners = bias?.soundsLike.map { Int32($0.termIndex) } ?? []
        let language = language.map(CStrings.init(single:)), prompt = prompt.map(CStrings.init(single:))
        var vocabulary = transcribe_parakeet_vocabulary_ext()
        transcribe_parakeet_vocabulary_ext_init(&vocabulary)
        return terms.pointers.withUnsafeBufferPointer { termList in
            spellings.pointers.withUnsafeBufferPointer { spellingList in
                owners.withUnsafeBufferPointer { ownerList in
                    var params = transcribe_run_params()
                    transcribe_run_params_init(&params)
                    params.language = language?.pointers[0]
                    params.prompt = prompt?.pointers[0]
                    if let bias {
                        params.vocabulary = termList.baseAddress
                        params.n_vocabulary = Int32(termList.count)
                        vocabulary.boost = bias.boost
                        vocabulary.sounds_like = spellingList.baseAddress
                        vocabulary.sounds_like_term = ownerList.baseAddress
                        vocabulary.n_sounds_like = Int32(spellingList.count)
                    }
                    return withUnsafePointer(to: &vocabulary) { ext in
                        // The extension's first field is the generic header the params point at.
                        if biasExtension { params.family = UnsafeRawPointer(ext).assumingMemoryBound(to: transcribe_ext.self) }
                        return withUnsafePointer(to: &params) { body($0) }
                    }
                }
            }
        }
    }
}

/// C copies of strings, freed with this object.
private final class CStrings {
    let pointers: [UnsafePointer<CChar>?]

    init(_ strings: [String]) { pointers = strings.map { UnsafePointer(strdup($0)) } }
    convenience init(single string: String) { self.init([string]) }

    deinit { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
}
