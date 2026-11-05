import AppKit
import CoreGraphics
import Foundation

// Metadata only: never read or interact with a system dialog. It must not turn a screen run into failures.
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
let systemDialog = ["com.apple.UserNotificationCenter", "com.apple.loginwindow"].contains(front)
let state: [String: Any] = ["locked": locked, "front": front, "blocked": locked || systemDialog]
let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
