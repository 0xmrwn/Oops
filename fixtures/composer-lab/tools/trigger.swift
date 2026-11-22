import Foundation

// Posts an oops debug trigger (honored only with DiagnosticsRemoteTrigger set): the placement
// preview by default, `trigger correct` for a real correction in oops's open test editor or in
// onboarding's Try it while it is in front (`restore` reverts the test editor's), or
// `trigger correct-lab` (`restore-lab`) for a real correction (revert) of a lab's draft when it is in front,
// `trigger action-lab <name> [value]` (`action-restore-lab`, `action-dismiss-lab`) to run a saved action on a lab's draft
// when it is in front (Debug, `-DebugActions YES`), `trigger agent-lab <name> [value] [options]` to run it as an agent
// (`options` as DebugHooks+Agent reads them), `agent-try <name>` in Settings' Try, and `agent-act`, `agent-dismiss`, `agent-cancel` or `agent-state`, wherever focus is,
// `trigger wheel-shortcut` (`wheel-key <key> [down|up|tap]`, `wheel-keys <spec>`, `wheel-mouse <move|click> <place|centre|outside>`,
// `wheel-state`, `wheel-tap-probe`) to drive the Actions wheel over a lab in front, `trigger wheel-library <json>` to set
// the wheel's actions without touching the saved ones (Debug, `-DebugActions YES`),
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
case "action-lab": "dev.0xmrwn.oops.action-lab"
case "action-restore-lab": "dev.0xmrwn.oops.action-restore-lab"
case "action-dismiss-lab": "dev.0xmrwn.oops.action-dismiss-lab"
case "agent-lab", "agent-try", "agent-act", "agent-dismiss", "agent-cancel", "agent-state": "dev.0xmrwn.oops." + arguments[0]
case "wheel-shortcut", "wheel-key", "wheel-keys", "wheel-mouse", "wheel-state", "wheel-tap-probe", "wheel-library":
    "dev.0xmrwn.oops." + arguments[0]
case "menu": "dev.0xmrwn.oops.menu"
case "forget": "dev.0xmrwn.oops.forget"
case "probe": "dev.0xmrwn.oops.probe"
case "app": "dev.0xmrwn.oops.app"
default: "dev.0xmrwn.oops.preview-placement"
}
let info: [String: String]? = switch arguments.first {
case "insert-lab": ["text": arguments.dropFirst().first ?? ""]
case "action-lab", "agent-lab", "agent-try":
    ["name": arguments.dropFirst().first ?? "", "value": arguments.count > 2 ? arguments[2] : "", "options": arguments.count > 3 ? arguments[3] : ""]
case "probe": ["mode": arguments.dropFirst().first ?? "plain"]
case "wheel-key": ["key": arguments.dropFirst().first ?? "", "phase": arguments.count > 2 ? arguments[2] : "tap"]
case "wheel-keys": ["spec": arguments.dropFirst().first ?? ""]
case "wheel-mouse" where arguments.count >= 3: ["kind": arguments[1], "at": arguments[2]]
case "wheel-library": ["path": arguments.dropFirst().first ?? ""]
case "app" where arguments.count >= 3: ["action": arguments[1], "bundle": arguments[2]].merging(arguments.count > 3 ? ["text": arguments[3]] : [:]) { a, _ in a }
default: nil
}
DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: info, deliverImmediately: true)
