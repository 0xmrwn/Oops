import CoreGraphics
import Foundation

// Watches Oops's flash for `seconds` and prints each new frame of its "Oops Highlights" panel as a
// JSON line {"x","y","w","h"} in global top-left points (Accessibility's coordinates). The panel is
// the union of the flashed rects grown by 8 points. Usage: flashes <seconds>
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
let deadline = Date().addingTimeInterval(seconds)
var last = ""
while Date() < deadline {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where window[kCGWindowOwnerName as String] as? String == "Oops"
        && window[kCGWindowName as String] as? String == "Oops Highlights" {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Double],
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        let line = String(format: "{\"x\":%.1f,\"y\":%.1f,\"w\":%.1f,\"h\":%.1f}", bounds["X"] ?? 0, bounds["Y"] ?? 0, bounds["Width"] ?? 0, bounds["Height"] ?? 0)
        if line != last { print(line); fflush(stdout); last = line }
    }
    Thread.sleep(forTimeInterval: 0.025)
}
