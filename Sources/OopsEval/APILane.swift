import Foundation
import OopsCore

/// One request's outcome, before it is decoded and scored.
struct Answer: Sendable {
    var raw: String?
    /// A 200 that failed the app's own response check, or an answer the provider refused as off-schema:
    /// the model's failure, so it scores `invalid` rather than `error`.
    var malformed = false
    var status: Int?
    var ttft: Int?, ttfc: Int?, total: Int?, harness: Int?
    var finish: String?, requestID: String?, modelReported: String?
    var tokens: CallRecord.Tokens?
    /// Set by lanes that know their own price (Claude Code reports one).
    var cost: Double?
    var error: String?
    /// A 429 or a spent quota.
    var limit: LimitSignal?
    /// A window the headers say is spent, though this request went through.
    var pause: Double?
    /// Worth one more try: a 5xx, a dropped connection.
    var transient = false
    /// The provider refused a setting and the lane has stepped down: send again.
    var resend = false
    var surface: String
    var effort: String?
}

protocol Lane: Sendable {
    func send(_ text: String) async -> Answer
    /// How the lane settled on its request, for the manifest.
    func notes() async -> [String]
}

func milliseconds(since start: ContinuousClock.Instant) -> Int { Int((start.duration(to: .now) / .milliseconds(1)).rounded()) }

/// OpenAI-compatible chat completions: the app's own request (`APIConfiguration.request`), streamed.
/// Streaming adds only `stream: true` and `stream_options.include_usage`; when a provider refuses
/// either, or an effort level, the lane steps down once and keeps that setting for the rest of the run.
actor APILane: Lane {
    enum Mode { case usage, plain, off }
    private enum Refusal { case streamOptions, stream, effort }

    let baseURL: URL, model: String, key: String
    private let efforts: [String?]
    private var effortIndex = 0
    private var mode = Mode.usage
    private var settled: [String] = []

    init(baseURL: URL, model: String, key: String, efforts: [String?]) {
        self.baseURL = baseURL; self.model = model; self.key = key; self.efforts = efforts.isEmpty ? [nil] : efforts
    }

    func notes() -> [String] { settled }

    func resume(from record: CallRecord) {
        if let index = efforts.firstIndex(of: record.effort) { effortIndex = index }
        mode = Self.modes.first { $0.value == record.surface }?.key ?? .usage
    }

    static let modes: [Mode: String] = [.usage: "chat-completions-stream", .plain: "chat-completions-stream-no-usage", .off: "chat-completions"]

    /// One request. A refused setting steps the lane down and asks to be sent again (through the pacer);
    /// only the request that ran with the current settings moves them, so concurrent refusals of the
    /// same setting step down once.
    func send(_ text: String) async -> Answer {
        let effortUsed = effortIndex, modeUsed = mode
        var (answer, refusal) = await once(text)
        guard let refusal else { return answer }
        if effortIndex != effortUsed || mode != modeUsed { answer.resend = true; return answer }
        switch refusal {
        case .streamOptions where mode == .usage, .stream where mode == .usage:
            mode = .plain; settled.append("HTTP \(answer.status ?? 0) to stream_options: streamed without usage")
        case .stream where mode == .plain:
            mode = .off; settled.append("HTTP \(answer.status ?? 0) to streaming: not streamed, no TTFT")
        case .effort where effortIndex + 1 < efforts.count:
            settled.append("HTTP \(answer.status ?? 0) to effort \(efforts[effortIndex] ?? "none"): \(efforts[effortIndex + 1] ?? "no effort") instead")
            effortIndex += 1
        default: return answer
        }
        answer.resend = true
        return answer
    }

    private func once(_ text: String) async -> (Answer, Refusal?) {
        let effort = efforts[effortIndex], surface = Self.modes[mode] ?? "chat-completions"
        var request: URLRequest
        do { request = try APIConfiguration(baseURL: baseURL, model: model, apiKey: key, reasoningEffort: effort).request(for: text) }
        catch { return (Answer(error: "request: \(error.localizedDescription)", surface: surface, effort: effort), nil) }
        if mode != .off, let body = request.httpBody, var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            object["stream"] = true
            if mode == .usage { object["stream_options"] = ["include_usage": true] }
            request.httpBody = try? JSONSerialization.data(withJSONObject: object)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        let started = ContinuousClock.now, sent = request
        do {
            var (answer, refusal) = try await withDeadline(.seconds(40), orThrow: URLError(.timedOut)) { try await Self.exchange(sent, started: started) }
            answer.surface = surface; answer.effort = effort
            return (answer, refusal)
        } catch let error as URLError where error.code == .timedOut {
            return (Answer(total: milliseconds(since: started), error: "deadline: no complete answer in 40 s", surface: surface, effort: effort), nil)
        } catch let error as URLError {
            return (Answer(total: milliseconds(since: started), error: "network: URLError \(error.code.rawValue)", transient: true, surface: surface, effort: effort), nil)
        } catch {
            return (Answer(total: milliseconds(since: started), error: "network", transient: true, surface: surface, effort: effort), nil)
        }
    }

    private static func exchange(_ request: URLRequest, started: ContinuousClock.Instant) async throws -> (Answer, Refusal?) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in http.allHeaderFields { headers[name.lowercased()] = value }
        var answer = Answer(status: http.statusCode, requestID: headers["x-request-id"] ?? headers["request-id"] ?? headers["cf-ray"], surface: "")
        let signal = LimitSignal.headers(headers, status: http.statusCode)
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
            answer.total = milliseconds(since: started)
            // Bodies can echo the draft: only a short machine code is kept, the message only classified.
            let (message, code) = detail(body)
            answer.error = "HTTP \(http.statusCode)" + (code.flatMap { $0 == String(http.statusCode) ? nil : " \($0)" } ?? "")
            switch http.statusCode {
            case 429:
                var limit = LimitSignal.body(String(decoding: body, as: UTF8.self))
                limit.wait = limit.wait ?? signal.wait; limit.daily = limit.daily || signal.daily
                answer.limit = limit
            case 408, 500...: answer.transient = true
            case 400, 422:
                if code == "json_validate_failed" { answer.malformed = true; return (answer, nil) }
                let lower = message.lowercased()
                if lower.contains("stream_options") { return (answer, .streamOptions) }
                if lower.contains("effort") || lower.contains("reasoning") { return (answer, .effort) }
                if lower.contains("stream") { return (answer, .stream) }
            default: break
            }
            return (answer, nil)
        }
        answer.pause = signal.wait
        let type = headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        if type == "text/event-stream" { try await stream(bytes, into: &answer, started: started) }
        else { try await whole(bytes, into: &answer, started: started) }
        return (answer, nil)
    }

    /// Server-sent chunks put back together, then held to the app's check: one choice, finished
    /// with `stop`, no refusal or tool call, text content.
    private static func stream(_ bytes: URLSession.AsyncBytes, into answer: inout Answer, started: ContinuousClock.Instant) async throws {
        var content: String?, finish: String?, indexes = Set<Int>(), refused = false, tools = false, size = 0
        for try await line in bytes.lines {
            size += line.utf8.count
            guard size <= 4_000_000 else { answer.error = "response too large"; answer.malformed = true; return }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if chunk["error"] != nil {
                // Groq reports an answer that broke the schema here once streaming has begun.
                let code = detail(Data(payload.utf8)).code
                answer.error = "error event in stream" + (code.map { " (\($0))" } ?? ""); answer.malformed = code == "json_validate_failed"
                answer.total = milliseconds(since: started); return
            }
            if let model = chunk["model"] as? String { answer.modelReported = model }
            if answer.requestID == nil, let id = chunk["id"] as? String { answer.requestID = id }
            if let usage = chunk["usage"] as? [String: Any] { answer.tokens = tokens(usage) }
            for case let choice as [String: Any] in chunk["choices"] as? [Any] ?? [] {
                indexes.insert((choice["index"] as? NSNumber)?.intValue ?? 0)
                if let reason = choice["finish_reason"] as? String { finish = reason }
                guard let delta = choice["delta"] as? [String: Any] else { continue }
                let piece = delta["content"] as? String
                let thinking = ["reasoning_content", "reasoning", "thinking"].contains { !((delta[$0] as? String) ?? "").isEmpty }
                    || !((delta["reasoning_details"] as? [Any]) ?? []).isEmpty
                if let refusal = delta["refusal"], !(refusal is NSNull) { refused = true }
                if let calls = delta["tool_calls"], !(calls is NSNull) { tools = true }
                if !(piece ?? "").isEmpty || thinking || tools { answer.ttft = answer.ttft ?? milliseconds(since: started) }
                if let piece {
                    if !piece.isEmpty { answer.ttfc = answer.ttfc ?? milliseconds(since: started) }
                    content = (content ?? "") + piece
                }
            }
        }
        answer.total = milliseconds(since: started); answer.finish = finish
        guard indexes == [0], finish == "stop", !refused, !tools, let content, content.utf8.count <= 256_000 else {
            answer.error = "The API did not return one complete structured correction."; answer.malformed = true; return
        }
        answer.raw = content
    }

    /// A provider that ignored `stream`, or the lane after streaming was refused: the app's check as is.
    private static func whole(_ bytes: URLSession.AsyncBytes, into answer: inout Answer, started: ContinuousClock.Instant) async throws {
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count > 256_000 { break } }
        answer.total = milliseconds(since: started)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        answer.modelReported = object?["model"] as? String
        if answer.requestID == nil { answer.requestID = object?["id"] as? String }
        if let usage = object?["usage"] as? [String: Any] { answer.tokens = tokens(usage) }
        let choices = object?["choices"] as? [[String: Any]]
        answer.finish = choices?.first?["finish_reason"] as? String
        guard data.count <= 256_000, let choices, choices.count == 1,
              choices[0]["finish_reason"] as? String == "stop",
              let message = choices[0]["message"] as? [String: Any],
              message["refusal"] == nil || message["refusal"] is NSNull,
              message["tool_calls"] == nil || message["tool_calls"] is NSNull,
              let raw = message["content"] as? String else {
            answer.error = "The API did not return one complete structured correction."; answer.malformed = true; return
        }
        answer.raw = raw
    }

    static func tokens(_ usage: [String: Any]) -> CallRecord.Tokens {
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        return CallRecord.Tokens(in: int(usage["prompt_tokens"]), out: int(usage["completion_tokens"]),
                                 reasoning: int((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]),
                                 cached: int((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]))
    }

    /// An error body's message (to classify, never kept) and its machine code (kept when short and plain).
    static func detail(_ body: Data) -> (message: String, code: String?) {
        var object = try? JSONSerialization.jsonObject(with: body)
        if let list = object as? [Any] { object = list.first }
        var fields = object as? [String: Any] ?? [:]
        if let errors = fields["errors"] as? [[String: Any]], let first = errors.first { fields = first }
        if let error = fields["error"] as? [String: Any] { fields = error }
        let message = (fields["message"] as? String) ?? (fields["error"] as? String) ?? ""
        let code = [fields["code"], fields["type"], fields["status"]].lazy.compactMap { value -> String? in
            if let number = value as? NSNumber { return number.stringValue }
            guard let text = value as? String, text.range(of: #"^[A-Za-z0-9_.-]{1,48}$"#, options: .regularExpression) != nil else { return nil }
            return text
        }.first
        return (message, code)
    }
}
