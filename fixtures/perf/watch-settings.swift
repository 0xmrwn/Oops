import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

private func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

private enum Refusal: String, Error {
    case captureAccess = "Screen Recording preflight refused access for this helper."
    case target = "Expected exactly one on-screen Oops Settings window for the verified app PID."
    case capture = "ScreenCaptureKit did not complete the bounded window capture."
    case evidence = "No usable WindowServer timestamp series, or the 2048-frame cap was reached."
}

private struct Anchor: Encodable {
    let before = mach_absolute_time()
    let epochSeconds = Date().timeIntervalSince1970
    let after = mach_absolute_time()
}

private struct Frame: Codable {
    let displayTicks: UInt64
    let meanDifference: Double
}

/// The SCStream callback and its reader serialize all state on the same queue.
private final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "oops.perf.window-sample")
    private var baseline: [Double]?
    private var frames: [Frame] = []
    private var counts: [Int: Int] = [:]
    private var limitReached = false

    func stream(_: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !limitReached,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int else { return }
        counts[raw, default: 0] += 1
        if counts.values.reduce(0, +) >= 2048 {
            limitReached = true
            return
        }
        guard let status = SCFrameStatus(rawValue: raw), status == .complete || status == .started,
              let ticks = info[.displayTime] as? UInt64, ticks > 0,
              let image = sample.imageBuffer, let values = fingerprint(image) else { return }
        if baseline == nil {
            baseline = values
            note("ready: baseline frame observed, switch General to About now")
        }
        guard let baseline else { return }
        let difference = zip(values, baseline).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(values.count)
        frames.append(Frame(displayTicks: ticks, meanDifference: difference))
    }

    func result() throws -> ([Frame], [Int: Int]) {
        try queue.sync {
            guard !limitReached, frames.count >= 2,
                  zip(frames, frames.dropFirst()).allSatisfy({ $0.displayTicks < $1.displayTicks }) else {
                throw Refusal.evidence
            }
            return (frames, counts)
        }
    }

    private func fingerprint(_ image: CVPixelBuffer) -> [Double]? {
        guard CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        var result: [Double] = []
        // The center of Settings excludes the title bar, tabs and outside desktop.
        // Sample small tiles so a thin glyph or cursor does not dominate the score.
        for row in 0..<8 {
            for column in 0..<12 {
                let x = width * (22 + column * 5) / 100
                let y = height * (30 + row * 6) / 100
                var sum = 0
                for dy in -3...3 {
                    for dx in -3...3 {
                        let i = (y + dy) * stride + (x + dx) * 4
                        sum += Int(bytes[i]) + 2 * Int(bytes[i + 1]) + Int(bytes[i + 2])
                    }
                }
                result.append(Double(sum) / (49 * 4 * 255))
            }
        }
        return result
    }
}

private struct Result: Encodable {
    let pid: Int32
    let windowID: UInt32
    let timebaseNumerator: UInt32
    let timebaseDenominator: UInt32
    let before: Anchor
    let after: Anchor
    let frames: [Frame]
    let statusCounts: [Int: Int]
}

@MainActor enum WatchSettings {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("Usage: watch-settings --pid PID --bundle /absolute/path/to/Oops.app")
            print("       watch-settings --preflight")
            print("Record at most 12 s of timestamps and change scores for one existing Settings window.")
            return
        }
        if args == ["--preflight"] {
            print(CGPreflightScreenCaptureAccess() ? "{\"screen_recording\":true}" : "{\"screen_recording\":false}")
            return
        }
        guard args.count == 4, args[0] == "--pid", let pid = Int32(args[1]), pid > 1,
              args[2] == "--bundle", args[3].hasPrefix("/") else {
            note("Pass --pid and --bundle as shown in --help.")
            exit(2)
        }
        do {
            let url = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
            let result = try await observe(pid: pid, url: url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(result) + Data([10]))
        } catch let error as Refusal {
            note(error.rawValue)
            exit(1)
        } catch {
            note("ScreenCaptureKit error code \((error as NSError).code).")
            exit(1)
        }
    }

    private static func observe(pid: Int32, url: URL) async throws -> Result {
        guard CGPreflightScreenCaptureAccess() else { throw Refusal.captureAccess }
        // A standalone executable needs its WindowServer connection before constructing the filter.
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CGMainDisplayID() != kCGNullDirectDisplay,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.resolvingSymlinksInPath().path == url.path else { throw Refusal.target }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            // On macOS 27 the tiny menu-bar window can also report layer zero.
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen &&
                $0.title == "Oops" && $0.frame.width >= 200 && $0.frame.height >= 200
        }
        guard windows.count == 1, let window = windows.first, window.frame.width > 0, window.frame.height > 0 else {
            throw Refusal.target
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = 480
        config.height = max(160, min(480, Int(480 * window.frame.height / window.frame.width)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = .zero
        let output = Frames()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        var scale = mach_timebase_info_data_t()
        guard mach_timebase_info(&scale) == KERN_SUCCESS, scale.denom > 0 else { throw Refusal.evidence }
        let before = Anchor()
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(12))
        try await stream.stopCapture()
        let after = Anchor()
        let (frames, counts) = try output.result()
        guard !app.isTerminated else { throw Refusal.target }
        return Result(pid: pid, windowID: window.windowID, timebaseNumerator: scale.numer,
                      timebaseDenominator: scale.denom, before: before, after: after,
                      frames: frames, statusCounts: counts)
    }
}

await WatchSettings.main()
