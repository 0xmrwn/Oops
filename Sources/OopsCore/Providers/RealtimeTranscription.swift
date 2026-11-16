import Foundation

/// OpenAI's realtime transcription wire format, as plain values: what the client sends and what it reads back.
/// Shapes follow the "Realtime transcription" and "WebSockets" guides; `gpt-live-transcribe` has no server-side
/// voice detection, so the client ends each turn itself.
public enum RealtimeTranscription {
    /// No `model` in the URL: the model-based URL opens a conversation session, which refuses the transcription update.
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    public static let model = "gpt-live-transcribe"
    /// The only rate the service takes.
    public static let sampleRate = 24_000

    /// The first frame of every connection. `turn_detection` is an explicit null: the model refuses both voice
    /// detections. `languages` (never the singular `language`) and `keywords` are sent only when there are some.
    public static func sessionUpdate(languages: [String], keywords: [String]) -> String {
        var transcription: [String: Any] = ["model": model]
        if !languages.isEmpty { transcription["languages"] = languages }
        if !keywords.isEmpty { transcription["keywords"] = keywords }
        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": sampleRate] as [String: Any],
            "transcription": transcription,
            "turn_detection": NSNull()
        ]
        return json(["type": "session.update", "session": ["type": "transcription", "audio": ["input": input]] as [String: Any]])
    }

    public static func append(_ base64: String) -> String {
        json(["type": "input_audio_buffer.append", "audio": base64])
    }

    public static let commit = #"{"type":"input_audio_buffer.commit"}"#

    /// The service rejects the whole update for a keyword with `<`, `>` or a line break, so such terms are dropped.
    public static func keywords(_ terms: [String]) -> [String] {
        terms.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.unicodeScalars.contains { "<>\r\n".unicodeScalars.contains($0) } }
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The server events the client acts on.
    public enum ServerEvent: Equatable, Sendable {
        case ready
        case committed(item: String)
        case delta(item: String, text: String)
        case completed(item: String, transcript: String)
        case failed(item: String)
        /// The error's `code`, which is all the client ever reports of it: its message may quote what was sent.
        case error(code: String?)
        case other

        public static func parse(_ text: String) -> ServerEvent {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let type = object["type"] as? String else { return .other }
            let item = object["item_id"] as? String ?? ""
            switch type {
            case "session.updated", "transcription_session.updated": return .ready
            case "input_audio_buffer.committed": return .committed(item: item)
            case "conversation.item.input_audio_transcription.delta":
                return .delta(item: item, text: object["delta"] as? String ?? "")
            case "conversation.item.input_audio_transcription.completed":
                return .completed(item: item, transcript: object["transcript"] as? String ?? "")
            case "conversation.item.input_audio_transcription.failed": return .failed(item: item)
            case "error": return .error(code: (object["error"] as? [String: Any])?["code"] as? String)
            default: return .other
            }
        }
    }
}
