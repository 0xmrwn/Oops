import Foundation
import OopsCore

/// The Responses API on ChatGPT sign-in or a project key, using the app's shared request contract.
/// The text comes from the app's own parser (`ResponseStream`); this lane only
/// reads the same events again for their times, usage and model.
struct ChatGPTLane: Lane {
    let auth: ChatGPTAuth?
    let apiKey: String?
    let session: URLSession
    let model: String
    let effort: String

    init(auth: ChatGPTAuth, model: String, effort: String) {
        self.auth = auth; apiKey = nil; session = auth.session; self.model = model; self.effort = effort
    }

    init(apiKey: String, model: String, effort: String, session: URLSession = .shared) {
        auth = nil; self.apiKey = apiKey; self.session = session; self.model = model; self.effort = effort
    }

    func notes() async -> [String] { [] }

    func send(_ text: String) async -> Answer {
        let surface = "responses-stream", started = ContinuousClock.now
        var answer: Answer
        do {
            answer = try await withDeadline(.seconds(40), orThrow: URLError(.timedOut)) { [self] in
                if let auth { return try await auth.withAccessToken { token in try await stream(text, token: token) } }
                guard let apiKey else { throw ChatGPTError("auth_missing", "No credential.") }
                return try await stream(text, token: apiKey)
            }
        } catch let error as URLError where error.code == .timedOut {
            answer = Answer(total: milliseconds(since: started), error: "deadline: no complete answer in 40 s", surface: "")
        } catch let error as ChatGPTError {
            answer = Answer(status: error.status, total: milliseconds(since: started), error: "chatgpt: \(error.code)", surface: "")
            Self.classify(error, into: &answer)
        } catch {
            answer = Answer(total: milliseconds(since: started), error: "chatgpt: network", transient: true, surface: "")
        }
        answer.surface = surface; answer.effort = effort
        return answer
    }

    private func stream(_ text: String, token: String) async throws -> Answer {
        let request = try ChatGPTBackend.request(model: model, effort: effort, serviceTier: nil, text: text, token: token)
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect.shared)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError("network_error", "No response.", retryable: true) }
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in http.allHeaderFields { headers[name.lowercased()] = value }
        var answer = Answer(status: http.statusCode, requestID: headers["x-request-id"], surface: "")
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            let error = ChatGPTError.api(try? JSONSerialization.jsonObject(with: body), status: http.statusCode)
            // A 401 is thrown so the sign-in refreshes and the call runs once more, as in the app.
            if http.statusCode == 401 { throw error }
            answer.total = milliseconds(since: started); answer.error = "chatgpt: \(error.code)"
            Self.classify(error, into: &answer)
            if answer.limit != nil { answer.limit?.wait = LimitSignal.headers(headers, status: 429).wait }
            return answer
        }
        if let type = headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), type != "text/event-stream" {
            answer.error = "chatgpt: invalid_stream"; answer.transient = true; return answer
        }
        var parser = ResponseStream(), line: [UInt8] = [], done = false
        do {
            for try await byte in bytes {
                if byte == 0x0A { inspect(line, into: &answer, started: started); line.removeAll(keepingCapacity: true) } else { line.append(byte) }
                if try parser.feed(byte) { done = true; break }
            }
            if !done { done = try parser.finish() }
        } catch let error as ChatGPTError {
            answer.total = milliseconds(since: started); answer.error = "chatgpt: \(error.code)"
            Self.classify(error, into: &answer)
            return answer
        }
        answer.total = milliseconds(since: started)
        if done { answer.raw = parser.text } else { answer.error = "chatgpt: stream_interrupted"; answer.transient = true }
        return answer
    }

    /// One server-sent line: deltas time the first token, `response.completed` carries usage.
    private func inspect(_ line: [UInt8], into answer: inout Answer, started: ContinuousClock.Instant) {
        guard line.starts(with: Array("data:".utf8)), let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5))) as? [String: Any], let type = event["type"] as? String else { return }
        if type.hasSuffix(".delta") { answer.ttft = answer.ttft ?? milliseconds(since: started) }
        if type == "response.output_text.delta" { answer.ttfc = answer.ttfc ?? milliseconds(since: started) }
        guard let response = event["response"] as? [String: Any] else { return }
        answer.modelReported = response["model"] as? String ?? answer.modelReported
        if answer.requestID == nil { answer.requestID = response["id"] as? String }
        if type == "response.completed" || type == "response.incomplete" {
            answer.finish = response["status"] as? String
            if let usage = response["usage"] as? [String: Any] {
                func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
                answer.tokens = CallRecord.Tokens(in: int(usage["input_tokens"]), out: int(usage["output_tokens"]),
                                                  reasoning: int((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"]),
                                                  cached: int((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"]))
            }
        }
    }

    /// The app's error codes sorted into limits, the model's own failures, and errors worth a retry.
    static func classify(_ error: ChatGPTError, into answer: inout Answer) {
        if ["usage_limit_reached", "subscription_sharing_usage_limit_exceeded", "insufficient_quota"].contains(error.code) {
            answer.limit = LimitSignal(wait: nil, daily: true)
        } else if error.code == "rate_limit_exceeded" || error.status == 429 {
            answer.limit = LimitSignal(wait: nil, daily: false)
        } else if ["refusal", "response_incomplete", "response_too_large"].contains(error.code) {
            answer.malformed = true
        } else if error.retryable || (error.status ?? 0) >= 500 { answer.transient = true }
    }
}
