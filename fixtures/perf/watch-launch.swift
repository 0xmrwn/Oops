import AppKit
import Darwin

private struct Clock {
    private let before = DispatchTime.now().uptimeNanoseconds
    let wall = Date().timeIntervalSince1970
    private let after = DispatchTime.now().uptimeNanoseconds

    var offset: Double { wall - Double(before + (after - before) / 2) / 1e9 }
    var bracketMilliseconds: Double { Double(after - before) / 1e6 }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

private func started(_ pid: pid_t, expected: URL) -> Double? {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    let bytes = path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    let actual = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    guard actual.resolvingSymlinksInPath().path == expected.path else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
}

enum WatchLaunch {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("Usage: watch-launch --bundle /absolute/path/to/Oops.app")
            print("Observe a single fresh launch for 30 s. Launch separately after the ready message.")
            return
        }
        guard args.count == 2, args[0] == "--bundle", args[1].hasPrefix("/") else {
            fail("Pass --bundle with the exact absolute path to a verified Release app.")
        }
        let bundle = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        guard let app = Bundle(url: bundle), let identifier = app.bundleIdentifier,
              let binary = app.executableURL?.resolvingSymlinksInPath() else {
            fail("Expected an app bundle with an executable.")
        }
        let workspace = NSWorkspace.shared
        guard workspace.runningApplications.allSatisfy({ $0.bundleIdentifier != identifier }) else {
            fail("An app with this bundle ID is already running. Use a fresh process.")
        }
        let clock = Clock()
        let deadline = DispatchTime.now() + .seconds(30)
        var listedWall: Double?
        FileHandle.standardError.write(Data("ready: waiting for the exact app launch\n".utf8))
        // didLaunchApplicationNotification is not delivered for LSUIElement apps.
        while DispatchTime.now() < deadline {
            if let running = workspace.runningApplications.first(where: {
                $0.bundleIdentifier == identifier && $0.bundleURL?.resolvingSymlinksInPath().path == bundle.path
            }) {
                if listedWall == nil { listedWall = Date().timeIntervalSince1970 }
                if running.isFinishedLaunching, let listedWall {
                    report(running.processIdentifier, binary: binary, clock: clock, listedWall: listedWall)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        fail("No finished launch for the exact app in 30 seconds.")
    }

    private static func report(_ pid: pid_t, binary: URL, clock: Clock, listedWall: Double) -> Never {
        let observed = Clock()
        guard let creation = started(pid, expected: binary),
              creation >= clock.wall, listedWall >= creation, observed.wall >= listedWall else {
            fail("Could not confirm a fresh process with the exact executable.")
        }
        let drift = abs(observed.offset - clock.offset) * 1000
        let bracket = max(observed.bracketMilliseconds, clock.bracketMilliseconds)
        guard drift <= 5, bracket <= 1 else {
            fail("Host clock shifted or the clock read was interrupted. Retry in a new run.")
        }
        let result: [String: Any] = [
            "boundary": "process-creation-to-workspace-finished-launch-observation",
            "pid": pid,
            "process_start_epoch_s": creation,
            "listed_observed_epoch_s": listedWall,
            "finished_observed_epoch_s": observed.wall,
            "elapsed_ms": (observed.wall - creation) * 1000,
            "poll_interval_ms": 5,
            "wall_clock_offset_drift_ms": drift,
            "clock_bracket_ms": bracket
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
            fail("Could not encode the launch observation.")
        }
        FileHandle.standardOutput.write(json + Data([10]))
        exit(0)
    }
}

MainActor.assumeIsolated { WatchLaunch.main() }
