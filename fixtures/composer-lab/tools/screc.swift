import AVFoundation
import AppKit
import ScreenCaptureKit

// usage (composer lab): screc <out.mov> <seconds> <x> <y> <w> <h> [bundle ids...]
// Records only oops's windows (including ones that appear later), cropped to a rect in global points.
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1]), seconds = Double(args[2])!
let crop = CGRect(x: Double(args[3])!, y: Double(args[4])!, width: Double(args[5])!, height: Double(args[6])!)
final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { print("finished"); exit(0) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { print("failed", error); exit(1) }
    func stream(_ stream: SCStream, didStopWithError error: Error) { print("stopped", error); exit(1) }
}
let delegate = Delegate()
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let bundles = Set(["dev.0xmrwn.oops"] + args.dropFirst(7))
        let apps = content.applications.filter { bundles.contains($0.bundleIdentifier) }
        guard !apps.isEmpty else { print("apps not running"); exit(1) }
        let display = content.displays[0]
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = crop
        config.width = Int(crop.width * 2); config.height = Int(crop.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = out; recordingConfig.outputFileType = .mov; recordingConfig.videoCodecType = .hevc
        let recording = SCRecordingOutput(configuration: recordingConfig, delegate: delegate)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        print("recording"); fflush(stdout)
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        try await Task.sleep(for: .seconds(2))
        print("done"); exit(0)
    } catch { print("error", error); exit(1) }
}
RunLoop.main.run()
