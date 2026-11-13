import Foundation

// Posts an oops debug trigger (honored only with DiagnosticsRemoteTrigger set): the placement
// preview by default, `trigger correct` for a real correction in oops's open test editor or in
// onboarding's Try it while it is in front (`restore` reverts the test editor's), or
// `trigger correct-lab` (`restore-lab`) for a real correction (revert) of a lab's draft when it is in front,
// `trigger insert-lab <text>` to insert text at the caret of a lab's field when it is in front,
// `trigger menu` to open the menu bar menu, `trigger forget` to drop the last correction (no toggle carries over), or
// `trigger probe [plain|manual|enhanced]` to record the focused editor's geometry like Diagnostics → Probe, or
// `trigger app <new|focus|outline|type|replace|remove|read|markers|attributes|correct|restore> <bundle id> [text]` for compatibility runs (fixtures/compat),
// which act only while that app is in front.
let arguments = Array(CommandLine.arguments.dropFirst())
let name = switch arguments.first {
case "correct": "dev.0xmrwn.oops.correct"
case "restore": "dev.0xmrwn.oops.restore"
case "correct-lab": "dev.0xmrwn.oops.correct-lab"
case "restore-lab": "dev.0xmrwn.oops.restore-lab"
case "insert-lab": "dev.0xmrwn.oops.insert-lab"
case "menu": "dev.0xmrwn.oops.menu"
case "forget": "dev.0xmrwn.oops.forget"
case "probe": "dev.0xmrwn.oops.probe"
case "app": "dev.0xmrwn.oops.app"
default: "dev.0xmrwn.oops.preview-placement"
}
let info: [String: String]? = switch arguments.first {
case "insert-lab": ["text": arguments.dropFirst().first ?? ""]
case "probe": ["mode": arguments.dropFirst().first ?? "plain"]
case "app" where arguments.count >= 3: ["action": arguments[1], "bundle": arguments[2]].merging(arguments.count > 3 ? ["text": arguments[3]] : [:]) { a, _ in a }
default: nil
}
DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: info, deliverImmediately: true)
