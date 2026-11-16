import Foundation

/// OpenAI's realtime transcription as a `SpeechEngine`. It holds a key and no connection: each dictation opens its own
/// socket, so there is nothing to load, warm or release between dictations.
public struct OpenAIRealtimeEngine: SpeechEngine {
    private let apiKey: String, endpoint: URL, transport: any RealtimeTransport, timeout: Duration

    public init(apiKey: String, endpoint: URL = RealtimeTranscription.endpoint,
                transport: any RealtimeTransport = URLSessionRealtimeTransport(), timeout: Duration = .seconds(10)) {
        self.apiKey = apiKey; self.endpoint = endpoint; self.transport = transport; self.timeout = timeout
    }

    public func load(model url: URL) async throws {}
    public func warmUp(model url: URL) async throws {}
    public func unload() async {}

    public func startStream(language: String?, vocabulary: VocabularyDelivery?) async throws -> any SpeechStream {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = TimeInterval(timeout.components.seconds)
        var terms: [String] = []
        if case let .openAIKeywords(list)? = vocabulary { terms = RealtimeTranscription.keywords(list) }
        let client = RealtimeTranscriptionClient(request: request, transport: transport, languages: language.map { [$0] } ?? [],
                                                 keywords: terms, timeout: timeout)
        await client.start()
        return client
    }

    /// For completeness: the app streams. All the samples go at once, then the turn is committed.
    public func transcribe(_ samples: [Float], language: String?, vocabulary: VocabularyDelivery?) async throws -> String {
        let stream = try await startStream(language: language, vocabulary: vocabulary)
        await stream.append(samples)
        return try await stream.finish()
    }
}
