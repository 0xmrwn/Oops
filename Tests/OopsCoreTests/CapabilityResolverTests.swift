import XCTest
@testable import OopsCore

final class CapabilityResolverTests: XCTestCase {
    private let groq = Provider.Kind.api(preset: "groq"), custom = Provider.Kind.api(preset: nil)
    private var feed: ModelsDevFeed { get throws { try ModelsDevFeed.decode(Data(modelsDevFixture.utf8)) } }
    private func resolver(feed: ModelsDevFeed? = nil, catalog: [String: ModelCapabilities] = [:]) -> CapabilityResolver {
        CapabilityResolver(catalog: { _, id in catalog[id] }, feed: feed)
    }

    func testCatalogDecidesFirst() throws {
        let known = ModelCapabilities(text: false, voice: true, streaming: true, languages: ["en"], source: .user)
        let resolved = resolver(feed: try feed, catalog: ["whisper-large-v3": known])
            .resolve(modelID: "whisper-large-v3", kind: groq, canProbe: true).capabilities
        XCTAssertEqual(resolved, ModelCapabilities(text: false, voice: true, streaming: true, languages: ["en"], source: .catalog))
        let local = resolver(catalog: ["parakeet-unified-en": known]).resolve(modelID: "parakeet-unified-en", kind: nil, canProbe: false)
        XCTAssertEqual(local.capabilities?.source, .catalog)
    }

    func testProviderReportDecidesBeforeTheFeedAndTheName() throws {
        let reported = ModelCapabilities(text: true, voice: false, source: .name)
        let resolved = resolver(feed: try feed).resolve(modelID: "whisper-large-v3", kind: groq, reported: reported, canProbe: true)
        XCTAssertEqual(resolved, .resolved(ModelCapabilities(text: true, voice: false, source: .provider)))
    }

    func testModelsDevDecidesByProviderOrCanonicalID() throws {
        let resolver = resolver(feed: try feed)
        // Neither name gives it away: only the feed knows Voxtral Mini transcribes.
        XCTAssertNil(ModelName.capabilities("voxtral-mini-latest"))
        XCTAssertEqual(resolver.resolve(modelID: "voxtral-mini-latest", kind: .api(preset: "mistral"), canProbe: true),
                       .resolved(.speechToText(streaming: false, source: .provider)))
        // OpenAI's and Google's own entries omit them; the canonical id finds them under other providers.
        XCTAssertEqual(resolver.resolve(modelID: "whisper-1", kind: .api(preset: "openai"), canProbe: true).capabilities?.source, .provider)
        XCTAssertEqual(resolver.resolve(modelID: "gpt-live-transcribe", kind: .api(preset: "openai"), canProbe: true),
                       .resolved(.speechToText(streaming: true, source: .provider)))
        XCTAssertEqual(resolver.resolve(modelID: "gemini-3.5-transcribe", kind: .api(preset: "gemini"), canProbe: true).capabilities?.voice, true)
    }

    func testNameDecidesWhatNothingBeforeItKnows() throws {
        let resolved = resolver(feed: try feed).resolve(modelID: "acme-asr-2", kind: custom, canProbe: true)
        XCTAssertEqual(resolved, .resolved(.speechToText(streaming: false, source: .name)))
        XCTAssertEqual(resolver().resolve(modelID: "tts-1", kind: .api(preset: "openai"), canProbe: true),
                       .resolved(ModelCapabilities(text: false, voice: false, source: .name)))
    }

    func testUnknownModelNeedsTheCheckThenItsStoredVerdictDecides() {
        let resolver = resolver()
        XCTAssertEqual(resolver.resolve(modelID: "mistral-small-latest", kind: .api(preset: "mistral"), canProbe: true), .needsProbe)
        XCTAssertEqual(resolver.resolve(modelID: "mistral-small-latest", kind: .api(preset: "mistral"), probe: .voice, canProbe: true),
                       .resolved(.speechToText(streaming: false, source: .probe)))
        XCTAssertEqual(resolver.resolve(modelID: "mistral-small-latest", kind: .api(preset: "mistral"), probe: .notVoice, canProbe: true),
                       .resolved(ModelCapabilities(text: true, voice: false, source: .probe)))
    }

    func testUnknownModelFallsThroughToTheUser() {
        let resolver = resolver()
        XCTAssertEqual(resolver.resolve(modelID: "mistral-small-latest", kind: custom, canProbe: false), .needsUserAnswer)
        // A check that couldn't tell isn't run again: the user is asked.
        XCTAssertEqual(resolver.resolve(modelID: "mistral-small-latest", kind: custom, probe: .inconclusive, canProbe: true), .needsUserAnswer)
        XCTAssertEqual(resolver.resolve(modelID: "mistral-small-latest", kind: custom, probe: .inconclusive, answer: true, canProbe: true),
                       .resolved(.speechToText(streaming: false, source: .user)))
        XCTAssertEqual(resolver.resolve(modelID: "mistral-small-latest", kind: custom, answer: false, canProbe: true),
                       .resolved(ModelCapabilities(text: true, voice: false, source: .user)))
    }

    func testSubscriptionsNeverTranscribe() throws {
        let voice = ModelCapabilities(text: false, voice: true, source: .catalog)
        let resolver = resolver(feed: try feed, catalog: ["whisper-1": voice, "gpt-live-transcribe": voice])
        for kind in [Provider.Kind.chatGPT, .claudeCode] {
            for id in ["whisper-1", "gpt-live-transcribe", "gpt-6-luna", "haiku"] {
                let resolved = resolver.resolve(modelID: id, kind: kind, probe: .voice, answer: true, canProbe: true)
                XCTAssertEqual(resolved, .resolved(ModelCapabilities(text: true, voice: false, source: .catalog)), "\(kind) \(id)")
            }
        }
    }

    func testLocalServersFollowTheSameOrder() throws {
        let ollama = Provider.Kind.api(preset: "ollama"), lmstudio = Provider.Kind.api(preset: "lmstudio")
        let resolver = resolver(feed: try feed)
        XCTAssertEqual(resolver.resolve(modelID: "qwen-4-8b", kind: lmstudio, canProbe: true), .needsProbe)
        XCTAssertEqual(resolver.resolve(modelID: "qwen-4-8b", kind: ollama, canProbe: false), .needsUserAnswer)
        XCTAssertEqual(resolver.resolve(modelID: "whisper-large-v3", kind: ollama, canProbe: true).capabilities?.source, .name)
        // Should a server start listing transcription models on models.dev, they arrive like anyone else's.
        let listed = try ModelsDevFeed.decode(Data(#"{"lmstudio":{"id":"lmstudio","models":{"m-voice":{"id":"m-voice","type":"transcription"}}}}"#.utf8))
        XCTAssertEqual(self.resolver(feed: listed).resolve(modelID: "m-voice", kind: lmstudio, canProbe: true),
                       .resolved(.speechToText(streaming: false, source: .provider)))
    }
}

final class CapabilityNameTests: XCTestCase {
    func testNamesClassifyOnlyByWholeWords() {
        // id → (text, voice, streaming); nil is "the name can't tell".
        let table: [(String, (Bool, Bool, Bool)?)] = [
            ("whisper-1", (false, true, false)),
            ("whisper-large-v3-turbo", (false, true, false)),
            ("openai/whisper-large-v3", (false, true, false)),
            ("distil-whisper-large-v3-en", (false, true, false)),
            ("faster-whisper-large-v3", (false, true, false)),
            ("gpt-4o-transcribe", (false, true, false)),
            ("gpt-4o-mini-transcribe", (false, true, false)),
            ("gpt-live-transcribe", (false, true, true)),
            ("gpt-realtime-whisper", (false, true, true)),
            ("mai-transcribe-2-streaming", (false, true, true)),
            ("qwen3-asr-flash", (false, true, false)),
            ("stepaudio-2.5-asr", (false, true, false)),
            ("grok-voice-stt-1.0", (false, true, false)),
            ("parakeet-tdt-0.6b-v3", (false, true, false)),
            ("tts-1", (false, false, false)),
            ("tts-1-hd", (false, false, false)),
            ("gpt-4o-mini-tts", (false, false, false)),
            ("text-embedding-3-small", (false, false, false)),
            ("gpt-audio", (true, false, false)),
            ("gpt-4o-audio-preview", (true, false, false)),
            ("gpt-realtime", (true, false, false)),
            ("voxtral-small-latest", nil),
            ("voxtral-mini-latest", nil),
            ("gpt-6-luna", nil),
            ("mistral-small-latest", nil),
            ("llama-4-scout", nil),
            // Words inside other words don't count.
            ("fastt-model", nil),
            ("basr-7b", nil),
        ]
        for (id, expected) in table {
            let found = ModelName.capabilities(id)
            XCTAssertEqual(found.map { [$0.text, $0.voice, $0.streaming] }, expected.map { [$0.0, $0.1, $0.2] }, id)
            if let found { XCTAssertEqual(found.source, .name, id) }
        }
    }
}
