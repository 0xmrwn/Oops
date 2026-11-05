import Foundation

/// Shared wire contract; authentication, deadlines and user-facing errors belong to each backend.
enum Responses {
    static let url = URL(string: "https://api.openai.com/v1/responses")!

    static func request(model: String, effort: String?, serviceTier: String?, text: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model, "instructions": CorrectionPolicy.instructions,
            "input": [["role": "user", "content": text]],
            "text": ["format": ["type": "json_schema", "name": "correction", "strict": true, "schema": CorrectionPolicy.schema]],
            "service_tier": serviceTier ?? "default", "store": false, "stream": true
        ]
        if let effort { body["reasoning"] = ["effort": effort] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func stream(request: URLRequest, session: URLSession) async throws -> String {
        let bytes: URLSession.AsyncBytes, response: URLResponse
        (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect.shared)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.network }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            throw ChatGPTError.api(try? JSONSerialization.jsonObject(with: body), status: http.statusCode)
        }
        // The direct route can omit Content-Type; events are still validated and must complete.
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
           type != "text/event-stream" { throw ChatGPTError("invalid_stream", "ChatGPT did not return the expected response stream.", retryable: true) }
        var parser = ResponseStream()
        for try await byte in bytes {
            try Task.checkCancellation()
            if try parser.feed(byte) { return parser.text }
        }
        try Task.checkCancellation()
        if try parser.finish() { return parser.text }
        throw ChatGPTError("stream_interrupted", "ChatGPT ended the response before completing it. Try again.", retryable: true)
    }
}

/// Server-sent events from the Responses API. Bounded: the draft is ≤16 k UTF-16 units.
public struct ResponseStream {
    public private(set) var text = ""
    private var line: [UInt8] = []
    private var data: [String] = []
    private var total = 0

    /// Returns true once `response.completed` has been seen.
    public init() {}

    public mutating func feed(_ byte: UInt8) throws -> Bool {
        total += 1
        guard total <= 4_000_000, line.count <= 1_000_000 else { throw ChatGPTError("response_too_large", "ChatGPT's response was too large.") }
        guard byte == 0x0A else { line.append(byte); return false }
        if line.last == 0x0D { line.removeLast() }
        let current = String(decoding: line, as: UTF8.self); line.removeAll(keepingCapacity: true)
        if current.isEmpty { return try dispatch() }
        if current.hasPrefix("data:") { data.append(String(current.dropFirst(current.hasPrefix("data: ") ? 6 : 5))) }
        return false
    }

    public mutating func finish() throws -> Bool {
        if !line.isEmpty, try feed(0x0A) { return true }
        return try dispatch()
    }

    private mutating func dispatch() throws -> Bool {
        defer { data.removeAll() }
        guard !data.isEmpty else { return false }
        let payload = data.joined(separator: "\n")
        if payload == "[DONE]" { return false }
        guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ChatGPTError("invalid_stream", "ChatGPT's response stream contained an invalid event. Try again.", retryable: true)
        }
        switch event["type"] as? String {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String else { throw ChatGPTError("invalid_stream", "Invalid response text delta.") }
            text += delta
            guard text.utf16.count <= 64_000 else { throw ChatGPTError("response_too_large", "ChatGPT's response was too large.") }
        case "response.refusal.delta", "response.refusal.done":
            throw ChatGPTError("refusal", "The model declined to correct this text. Nothing replaced.")
        case "response.failed": throw ChatGPTError.api(event["response"], status: nil)
        case "error": throw ChatGPTError.api(event, status: nil)
        case "response.incomplete":
            throw ChatGPTError("response_incomplete", "ChatGPT stopped before finishing the correction. Nothing replaced.", retryable: true)
        case "response.completed":
            guard let response = event["response"] as? [String: Any],
                  response["status"] == nil || response["status"] as? String == "completed",
                  response["error"] == nil || response["error"] is NSNull else {
                throw ChatGPTError("invalid_stream", "The response did not complete successfully.")
            }
            var snapshot = ""
            for case let item as [String: Any] in response["output"] as? [Any] ?? [] where item["type"] as? String == "message" {
                for case let part as [String: Any] in item["content"] as? [Any] ?? [] {
                    if part["type"] as? String == "refusal" {
                        throw ChatGPTError("refusal", "The model declined to correct this text. Nothing replaced.")
                    }
                    if part["type"] as? String == "output_text" { snapshot += part["text"] as? String ?? "" }
                }
            }
            // Deltas are authoritative; the completed snapshot covers a stream that sent none.
            if text.isEmpty { text = snapshot }
            guard !text.isEmpty, text.utf16.count <= 64_000 else {
                throw ChatGPTError("invalid_stream", "The response contained no bounded correction text.")
            }
            return true
        default: break
        }
        return false
    }
}
