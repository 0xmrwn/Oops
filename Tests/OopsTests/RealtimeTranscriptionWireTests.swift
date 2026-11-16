import Foundation
import OopsCore
import Testing

/// The realtime wire format: what is sent, and which server events the client reads.
struct RealtimeTranscriptionWireTests {
    private typealias Event = RealtimeTranscription.ServerEvent

    @Test func `every server event the client uses parses`() {
        #expect(Event.parse(#"{"type":"session.updated","session":{}}"#) == .ready)
        #expect(Event.parse(#"{"type":"transcription_session.updated"}"#) == .ready)
        #expect(Event.parse(#"{"type":"input_audio_buffer.committed","item_id":"i1"}"#) == .committed(item: "i1"))
        #expect(Event.parse(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":"Hel"}"#)
            == .delta(item: "i1", text: "Hel"))
        #expect(Event.parse(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"Hello"}"#)
            == .completed(item: "i1", transcript: "Hello"))
        #expect(Event.parse(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"i1"}"#) == .failed(item: "i1"))
        #expect(Event.parse(#"{"type":"error","error":{"type":"x","code":"invalid_value","message":"secret words"}}"#)
            == .error(code: "invalid_value"))
        #expect(Event.parse(#"{"type":"error"}"#) == .error(code: nil))
    }

    @Test func `unknown events are ignored`() {
        #expect(Event.parse(#"{"type":"session.created"}"#) == .other)
        #expect(Event.parse(#"{"type":"rate_limits.updated"}"#) == .other)
        #expect(Event.parse(#"{"no":"type"}"#) == .other)
        #expect(Event.parse("not json") == .other)
        #expect(Event.parse("{}") == .other)
    }

    @Test func `the session update has the documented shape`() throws {
        let text = RealtimeTranscription.sessionUpdate(languages: ["fr"], keywords: ["Ghostty"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        let expected: NSDictionary = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": ["model": "gpt-live-transcribe", "languages": ["fr"], "keywords": ["Ghostty"]],
                    "turn_detection": NSNull()
                ]]
            ]
        ]
        #expect(object == expected)
    }

    @Test func `append and commit carry the type and audio`() throws {
        let append = try #require(try JSONSerialization.jsonObject(with: Data(RealtimeTranscription.append("AAAA").utf8)) as? [String: String])
        #expect(append == ["type": "input_audio_buffer.append", "audio": "AAAA"])
        let commit = try #require(try JSONSerialization.jsonObject(with: Data(RealtimeTranscription.commit.utf8)) as? [String: String])
        #expect(commit == ["type": "input_audio_buffer.commit"])
    }

    @Test func `keywords the service would reject are dropped`() {
        #expect(RealtimeTranscription.keywords(["a", "<b>", "c\r", "d\ne", " f ", "  "]) == ["a", "f"])
    }
}
