#if DEBUG
import Foundation
import OopsCore

/// End-to-end runs only (`-StubProvider <control.json>`, a launch argument, never saved): answers
/// from a file the runner rewrites before each scenario, so no model is called. The file holds
/// `answer` (returned as the schema object), `raw` (returned verbatim) or `fail` (offline, slow,
/// signIn, limit, setup or any other text), and optionally `delayMs`. A missing file echoes. Each call
/// counts itself in `<control>.calls`, so a run can tell a press that asked from one that didn't.
struct StubBackend: CorrectionBackend {
    let control: URL

    func complete(_ text: String) async throws -> String {
        let calls = control.appendingPathExtension("calls")
        let count = (try? String(contentsOf: calls, encoding: .utf8)).flatMap { Int($0) } ?? 0
        try? String(count + 1).write(to: calls, atomically: true, encoding: .utf8)
        let script = (try? Data(contentsOf: control)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let delay = script["delayMs"] as? Int { try await Task.sleep(for: .milliseconds(delay)) }
        if let fail = script["fail"] as? String {
            let reason: CorrectionError.Reason? = switch fail {
            case "offline": .offline
            case "slow": .slow
            case "signIn": .signIn
            case "limit": .limit
            case "setup": .setup
            default: nil
            }
            throw reason.map { CorrectionError.failure($0, "Stub failure: \(fail).") } ?? CorrectionError.message("Stub failure: \(fail).")
        }
        if let raw = script["raw"] as? String { return raw }
        let answer = script["answer"] as? String ?? text
        return String(decoding: try JSONSerialization.data(withJSONObject: ["text": answer]), as: UTF8.self)
    }
}
#endif
