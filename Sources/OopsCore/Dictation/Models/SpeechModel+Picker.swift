import Foundation

/// Who made a model's weights, for the mark the picker shows. A community fine-tune has none.
public enum SpeechModelMaker: String, Sendable, Equatable {
    case nvidia, openAI, cohere, qwen, alibaba, ibm
}

/// How long the words take once the speaker stops, in the picker's three steps.
public enum SpeechModelWait: Int, Sendable, Comparable {
    /// Transcribes after the recording, slower than thirty times real time on Hex's machine.
    case seconds = 1
    case underASecond
    /// Writes while the speaker talks.
    case live

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .live: "Live"
        case .underASecond: "< 1 s"
        case .seconds: "2 s"
        }
    }
}

public extension SpeechModel {
    var maker: SpeechModelMaker? {
        switch id {
        case "parakeet_unified_en", "parakeet_v2", "parakeet_v3", "nemotron_3_5_asr": .nvidia
        case "whisper_large_v3_turbo": .openAI
        case "cohere_transcribe": .cohere
        case "qwen3_asr06_b": .qwen
        case "sense_voice_small": .alibaba
        case "granite_speech_5": .ibm
        default: nil
        }
    }

    /// From what the catalog records: a streaming model is live; the others by Hex's speed label (`~33x`).
    var wait: SpeechModelWait {
        if streams { return .live }
        let factor = Double(realtime.filter { $0.isNumber || $0 == "." }) ?? 0
        return factor >= 30 ? .underASecond : .seconds
    }

    /// Words right in a hundred, from the catalog's word error rate. The benchmarks differ between entries.
    var accuracy: Double? { wordErrorRate.map { 100 - $0 } }

    /// "731 MB", "2.41 GB": whole megabytes, as the catalog's own figures read.
    var downloadSize: String {
        let megabytes = Double(artifact.byteCount) / 1_000_000
        return megabytes < 1000 ? "\(Int(megabytes.rounded())) MB" : "\((megabytes / 1000).formatted(.number.precision(.fractionLength(2)))) GB"
    }

    /// One name, or how many.
    var languageSummary: String {
        let codes = languages.codes
        return codes.count == 1 ? SpeechLanguage.name(of: codes[0]) : "\(codes.count) languages"
    }

    /// The weights' page.
    var page: URL? { URL(string: "https://huggingface.co/\(artifact.repository)") }
}

/// What the picker shows for a language: its picks as cards, then every model as a list.
public struct SpeechModelPicks: Sendable, Equatable {
    public let picks: [SpeechModelChoice]
    /// The other models that take the language, in the catalog's order, then those that don't.
    public let others: [SpeechModel]
    public let elsewhere: [SpeechModel]
    /// The pick that stands out on each fact, shown stronger; nil when the picks tie or there is one.
    public let mostAccurate: String?
    public let shortestWait: String?
    public let mostLanguages: String?

    public init(language: String, models: [SpeechModel] = SpeechModelCatalog.models) {
        let known = Set(models.map(\.id))
        let chosen = SpeechModelCatalog.choices(for: language).filter { known.contains($0.model.id) }
        let cards = chosen.map(\.model)
        let rest = models.filter { model in !cards.contains { $0.id == model.id } }
        picks = chosen
        others = rest.filter { $0.supports(language: language) }
        elsewhere = rest.filter { !$0.supports(language: language) }
        mostAccurate = Self.only(cards, by: { $0.accuracy ?? 0 })
        shortestWait = Self.only(cards, by: { Double($0.wait.rawValue) })
        mostLanguages = Self.only(cards, by: { Double($0.languages.codes.count) })
    }

    /// The one model with the highest value.
    private static func only(_ models: [SpeechModel], by value: (SpeechModel) -> Double) -> String? {
        guard models.count > 1, let best = models.map(value).max() else { return nil }
        let leaders = models.filter { value($0) == best }
        return leaders.count == 1 ? leaders[0].id : nil
    }
}
