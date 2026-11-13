import Foundation

// A port of the model catalog of Hex at v3.4.0 (MIT, github.com/anomalyco/hex): `ModelDefinition` and
// `GgufArtifact` in `src/transcription/models.rs`, with the pinned files of `src/transcription/artifacts.rs`.
// Hex's Labs gating, imports, Apple Speech entry and download bookkeeping have no place here. See
// THIRD_PARTY_NOTICES.md.

/// A pinned file on Hugging Face: the exact revision, size and checksum a download is verified against.
public struct SpeechModelArtifact: Sendable, Equatable {
    public let fileName: String
    public let repository: String
    public let revision: String
    public let byteCount: Int64
    public let sha256: String

    /// The Hugging Face resolve URL of this revision's file, as Hex's `download_url` builds it.
    public var url: URL {
        // The pieces are catalog constants, so a malformed one is a programmer error the catalog tests catch.
        guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)") else {
            preconditionFailure("The catalog's \(fileName) has no URL")
        }
        return url
    }

    public init(fileName: String, repository: String, revision: String, byteCount: Int64, sha256: String) {
        self.fileName = fileName
        self.repository = repository
        self.revision = revision
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// The languages a model transcribes, as language codes without a region (`fr`, `yue`).
public enum SpeechModelLanguages: Sendable, Equatable {
    case one(String)
    case many([String])
    /// Hex's `"*"`: every language Hex knows (`SpeechLanguage.known`), which Whisper takes beyond the ones Settings lists.
    case anyKnown

    /// The codes the model declares; every known one for `.anyKnown`.
    public var codes: [String] {
        switch self {
        case let .one(code): [code]
        case let .many(codes): codes
        case .anyKnown: SpeechLanguage.known
        }
    }

    public var isSingleLanguage: Bool {
        if case .one = self { return true }
        return false
    }

    public func supports(_ code: String) -> Bool {
        codes.contains(code)
    }
}

/// The licence of a model's weights. Hex records one only for the entries whose file comments name it.
public struct SpeechModelLicense: Sendable, Equatable {
    public let name: String
    public let url: URL?

    /// Hex names no licence for this entry; the weights' own card has to be read.
    public static let unrecorded = SpeechModelLicense(name: "Not recorded", url: nil)

    public var isRecorded: Bool { self != .unrecorded }

    public init(name: String, url: URL? = nil) {
        self.name = name
        self.url = url
    }
}

/// The model family transcribe.cpp loads a file as; Hex's `architecture` metadata string.
public enum SpeechModelArchitecture: String, Sendable, Equatable {
    case parakeet
    case whisper
    case qwen3ASR = "qwen3_asr"
    case senseVoice = "sensevoice"
    case cohereASR = "cohere_asr"
    case gigaAM = "gigaam"
    case graniteSpeech5CTC = "granite_speech5_ctc"
    case sileroVAD = "silero_vad"
}

/// How a model's transcription takes the user's vocabulary.
public enum SpeechModelVocabularyUse: Sendable, Equatable {
    /// Parakeet's transducer heads bias their decode toward the terms.
    case bias
    /// Whisper and Qwen3-ASR read the terms as their context prompt.
    case prompt
    case none
}

/// A model's streaming context in milliseconds: the audio it buffers before, at and after each chunk.
public struct SpeechModelStreamingChunk: Sendable, Equatable {
    public let leftMilliseconds: Int
    public let chunkMilliseconds: Int
    public let rightMilliseconds: Int

    public init(leftMilliseconds: Int, chunkMilliseconds: Int, rightMilliseconds: Int) {
        self.leftMilliseconds = leftMilliseconds
        self.chunkMilliseconds = chunkMilliseconds
        self.rightMilliseconds = rightMilliseconds
    }
}

/// One speech-to-text model of the catalog.
public struct SpeechModel: Sendable, Identifiable, Equatable {
    /// Hex's stable wire name (`parakeet_v3`), kept so a saved choice survives.
    public let id: String
    public let name: String
    public let artifact: SpeechModelArtifact
    public let architecture: SpeechModelArchitecture
    /// transcribe.cpp's name for the checkpoint inside its architecture.
    public let variant: String
    public let languages: SpeechModelLanguages
    /// The pinned file advertises streaming. Hex streams it only on a GPU after a load probe succeeds.
    public let streams: Bool
    /// The buffering Hex's comments name as the model's most accurate streaming setting; nil when it names none.
    public let streamingChunk: SpeechModelStreamingChunk?
    public let acceptsLanguageHint: Bool
    public let supportsLanguageDetection: Bool
    /// Codes the model takes under another name: Whisper's `tl` for `fil`, Nemotron's locales.
    public let runtimeLanguages: [String: String]
    public let license: SpeechModelLicense
    /// Word error rate in percent on the benchmark Hex's comments cite; the sets differ between entries.
    public let wordErrorRate: Double?
    /// Hex's speed label on its own GPU (`~33x` real time).
    public let realtime: String

    public var isSingleLanguage: Bool { languages.isSingleLanguage }

    public var vocabularyUse: SpeechModelVocabularyUse {
        switch architecture {
        case .parakeet: .bias
        case .whisper, .qwen3ASR: .prompt
        default: .none
        }
    }

    public func supports(language code: String) -> Bool {
        code == SpeechLanguage.auto ? supportsLanguageDetection : languages.supports(code)
    }

    /// The language to pass the engine as a hint: none under Auto or when the model takes no hint.
    public func runtimeLanguageHint(for code: String) -> String? {
        guard code != SpeechLanguage.auto, acceptsLanguageHint else { return nil }
        return runtimeLanguages[code] ?? code
    }

    public init(
        id: String, name: String, artifact: SpeechModelArtifact, architecture: SpeechModelArchitecture,
        variant: String, languages: SpeechModelLanguages, streams: Bool = false,
        streamingChunk: SpeechModelStreamingChunk? = nil, acceptsLanguageHint: Bool,
        supportsLanguageDetection: Bool, runtimeLanguages: [String: String] = [:],
        license: SpeechModelLicense = .unrecorded, wordErrorRate: Double?, realtime: String
    ) {
        self.id = id
        self.name = name
        self.artifact = artifact
        self.architecture = architecture
        self.variant = variant
        self.languages = languages
        self.streams = streams
        self.streamingChunk = streamingChunk
        self.acceptsLanguageHint = acceptsLanguageHint
        self.supportsLanguageDetection = supportsLanguageDetection
        self.runtimeLanguages = runtimeLanguages
        self.license = license
        self.wordErrorRate = wordErrorRate
        self.realtime = realtime
    }
}
