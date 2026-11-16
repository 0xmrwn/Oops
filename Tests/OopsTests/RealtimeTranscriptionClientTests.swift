import Foundation
import OopsCore
import Testing

/// The client and engine against a WebSocket stub on the loopback: no network, no key.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RealtimeTranscriptionClientTests {
    private func engine(_ stub: RealtimeTranscriptionStub, timeout: Duration = .seconds(5)) -> OpenAIRealtimeEngine {
        OpenAIRealtimeEngine(apiKey: "test-key", endpoint: stub.url, timeout: timeout)
    }

    private func frames(_ stub: RealtimeTranscriptionStub) -> [[String: Any]] {
        stub.snapshot.frames.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    private func types(_ stub: RealtimeTranscriptionStub) -> [String] { frames(stub).compactMap { $0["type"] as? String } }

    private func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.05) }
    }

    private func transcription(_ frame: [String: Any]) -> [String: Any]? {
        (((frame["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any])?["transcription"] as? [String: Any]
    }

    private func firstUpdate(_ stub: RealtimeTranscriptionStub) throws -> [String: Any] {
        let first = try #require(frames(stub).first)
        return try #require(transcription(first))
    }

    @Test func `the session update goes first and asks for live transcription at 24 kHz`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .complete("ok")))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub).startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 0.3))
        _ = try await stream.finish()

        let first = try #require(frames(stub).first)
        #expect(first["type"] as? String == "session.update")
        let session = try #require(first["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        let input = try #require((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(transcription(first)?["model"] as? String == "gpt-live-transcribe")
        #expect(input.keys.contains("turn_detection") && input["turn_detection"] is NSNull)
        #expect(stub.snapshot.authorization == "Bearer test-key")
    }

    @Test func `audio appended before the session is ready is sent once it is`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(readyAfter: .milliseconds(150), ending: .complete("ok")))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub).startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 1))
        _ = try await stream.finish()

        #expect(stub.snapshot.earlyAppends == 0)
        #expect(types(stub).first == "session.update")
        let samples = frames(stub).filter { $0["type"] as? String == "input_audio_buffer.append" }
            .compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0) } }
            .reduce(0) { $0 + $1.count / 2 }
        #expect(samples == 24_000)
    }

    @Test func `release commits once and returns the completed transcript`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .complete("Hello there.")))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub).startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 0.5))
        #expect(try await stream.finish() == "Hello there.")
        let sent = types(stub)
        #expect(sent.filter { $0 == "input_audio_buffer.commit" }.count == 1)
        #expect(sent.last == "input_audio_buffer.commit")
    }

    @Test func `deltas become live words`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(deltas: ["Hello", " there", " friend"], ending: .complete("Hello there friend.")))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub).startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 0.3))
        _ = try await stream.finish()
        var seen: [String] = []
        for await words in stream.words { seen.append(words.text) }
        #expect(seen == ["Hello", "Hello there", "Hello there friend"])
    }

    @Test func `a refused connection fails finish`() async throws {
        let stub = try await RealtimeTranscriptionStub.start()
        let refused = engine(stub)
        await stub.stop()
        let stream = try await refused.startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 0.3))
        await #expect(throws: SpeechEngineError.hostedFailed("connection")) { try await stream.finish() }
    }

    @Test func `an error event fails finish`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .errorEvent))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub).startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 0.3))
        await #expect(throws: SpeechEngineError.hostedFailed("error invalid_keyword")) { try await stream.finish() }
        #expect(!types(stub).contains("input_audio_buffer.commit"))
    }

    @Test func `no completion within the timeout fails finish`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .silent))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub, timeout: .milliseconds(100)).startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 0.3))
        await #expect(throws: SpeechEngineError.hostedFailed("timeout")) { try await stream.finish() }
        #expect(types(stub).filter { $0 == "input_audio_buffer.commit" }.count <= 1)
    }

    @Test func `cancel closes without committing`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .complete("never")))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub).startStream(language: nil, vocabulary: nil)
        await stream.append(speech(seconds: 0.3))
        await stub.wait { $0.frames.contains { $0.contains("session.update") } }
        await stream.cancel()
        await stream.cancel()
        await stub.wait { $0.closed }
        #expect(!types(stub).contains("input_audio_buffer.commit"))
        for await _ in stream.words {}
        await #expect(throws: SpeechEngineError.self) { try await stream.finish() }
    }

    @Test func `language and keywords reach the session update, and forbidden keywords are dropped`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .complete("")))
        defer { Task { await stub.stop() } }
        let terms = ["Ghostty", "bad<term>", "two\nlines", "  Oops  ", ""]
        let stream = try await engine(stub).startStream(language: "fr", vocabulary: .openAIKeywords(terms))
        _ = try await stream.finish()
        let update = try firstUpdate(stub)
        #expect(update["languages"] as? [String] == ["fr"])
        #expect(update["keywords"] as? [String] == ["Ghostty", "Oops"])
        #expect(update["language"] == nil)
    }

    @Test func `no language and another kind of vocabulary send neither`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .complete("")))
        defer { Task { await stub.stop() } }
        let stream = try await engine(stub).startStream(language: nil, vocabulary: .prompt("Ghostty"))
        _ = try await stream.finish()
        let update = try firstUpdate(stub)
        #expect(update["languages"] == nil && update["keywords"] == nil)
    }

    @Test func `two dictations back to back share nothing`() async throws {
        let stub = try await RealtimeTranscriptionStub.start(.init(ending: .complete("again")))
        defer { Task { await stub.stop() } }
        let engine = engine(stub)
        for _ in 0..<2 {
            let stream = try await engine.startStream(language: nil, vocabulary: nil)
            await stream.append(speech(seconds: 0.2))
            #expect(try await stream.finish() == "again")
        }
        #expect(types(stub).filter { $0 == "session.update" }.count == 2)
    }
}
