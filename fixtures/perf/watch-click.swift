import AppKit
import CoreGraphics

private func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

private func refuse(_ message: String, status: Int32 = 1) -> Never {
    note(message)
    exit(status)
}

private struct Click: Encodable {
    let pid: pid_t
    let windowID: CGWindowID
    let timestampNs: UInt64
    let callbackMachTicks: UInt64
    let callbackUptimeNs: UInt64
    let timebaseNumerator: UInt32
    let timebaseDenominator: UInt32
}

private final class Observer {
    let pid: pid_t
    let windowID: CGWindowID
    let region: CGRect
    let armedAtNs: UInt64
    let scale: mach_timebase_info_data_t
    var click: Click?
    var disabled = false

    init(pid: pid_t, windowID: CGWindowID, region: CGRect, scale: mach_timebase_info_data_t) {
        self.pid = pid
        self.windowID = windowID
        self.region = region
        self.scale = scale
        armedAtNs = DispatchTime.now().uptimeNanoseconds
    }

    func receive(_ event: CGEvent, type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disabled = true
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        guard type == .leftMouseDown, click == nil, region.contains(event.location) else { return }
        let target = event.getIntegerValueField(.eventTargetUnixProcessID)
        // The tap is PID-scoped. Reject contradictory metadata if the OS supplied it.
        guard target == 0 || target == Int64(pid) else { return }
        let timestamp = event.timestamp
        let machTicks = mach_absolute_time()
        let uptimeNs = DispatchTime.now().uptimeNanoseconds
        let machNs = Double(machTicks) * Double(scale.numer) / Double(scale.denom)
        guard timestamp >= armedAtNs, timestamp <= uptimeNs, uptimeNs - timestamp <= 250_000_000,
              abs(machNs - Double(uptimeNs)) <= 1_000_000 else { return }
        click = Click(pid: pid, windowID: windowID, timestampNs: timestamp, callbackMachTicks: machTicks,
                      callbackUptimeNs: uptimeNs, timebaseNumerator: scale.numer, timebaseDenominator: scale.denom)
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

private func settingsWindow(pid: pid_t, containing region: CGRect) -> CGWindowID? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = windows.compactMap { window -> CGWindowID? in
        guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
              window[kCGWindowLayer as String] as? Int == 0,
              window[kCGWindowName as String] as? String == "Oops",
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width >= 200, frame.height >= 200, frame.contains(region) else { return nil }
        return window[kCGWindowNumber as String] as? CGWindowID
    }
    return matches.count == 1 ? matches.first : nil
}

@MainActor private func watchClick() {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] {
        print("Usage: watch-click --pid PID --bundle /absolute/path/to/Oops.app --roi X Y WIDTH HEIGHT")
        print("       watch-click --preflight")
        print("Observe one left mouse-down in the verified Settings window. ROI uses global Quartz points.")
        return
    }
    if args == ["--preflight"] {
        print("{\"listen_mouse_event\":\(CGPreflightListenEventAccess()),\"post_event\":\(CGPreflightPostEventAccess())}")
        return
    }
    guard args.count == 9, args[0] == "--pid", let pid = pid_t(args[1]), pid > 1,
          args[2] == "--bundle", args[3].hasPrefix("/"), args[4] == "--roi" else {
        refuse("Pass --pid, --bundle and --roi as shown in --help.", status: 2)
    }
    let points = args[5...].compactMap(Double.init)
    guard points.count == 4, points.allSatisfy(\.isFinite),
          points[2] > 0, points[2] <= 180, points[3] > 0, points[3] <= 60 else {
        refuse("ROI must be a small, finite About-button rectangle in global Quartz points.", status: 2)
    }
    guard CGPreflightListenEventAccess() else { refuse("Input Monitoring preflight refused listen-only access.") }
    NSApplication.shared.setActivationPolicy(.prohibited)
    let expected = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
          app.bundleURL?.resolvingSymlinksInPath().path == expected.path else {
        refuse("Expected the verified Oops Settings process.")
    }
    let region = CGRect(x: points[0], y: points[1], width: points[2], height: points[3])
    guard let window = settingsWindow(pid: pid, containing: region) else {
        refuse("ROI is outside a unique, on-screen Oops Settings window.")
    }
    var scale = mach_timebase_info_data_t()
    guard mach_timebase_info(&scale) == KERN_SUCCESS, scale.denom > 0 else { refuse("Mach timebase unavailable.") }
    let observer = Observer(pid: pid, windowID: window, region: region, scale: scale)
    let events = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
    guard let tap = CGEvent.tapCreateForPid(
        pid: pid, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: events,
        callback: { _, type, event, context in
            if let context { Unmanaged<Observer>.fromOpaque(context).takeUnretainedValue().receive(event, type: type) }
            return Unmanaged.passUnretained(event)
        },
        userInfo: Unmanaged.passUnretained(observer).toOpaque()
    ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
        refuse("Could not open a listen-only tap for the exact process.")
    }
    let loop = CFRunLoopGetMain()
    CFRunLoopAddSource(loop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    note("ready: waiting up to 12 seconds for one About-button mouse-down")
    CFRunLoopRunInMode(.defaultMode, 12, false)
    CGEvent.tapEnable(tap: tap, enable: false)
    CFRunLoopRemoveSource(loop, source, .commonModes)
    guard !observer.disabled, !app.isTerminated, let click = observer.click else {
        refuse("No qualifying mouse-down was delivered to the verified PID and ROI.")
    }
    guard let data = try? JSONEncoder().encode(click) else { refuse("Could not encode the click observation.") }
    FileHandle.standardOutput.write(data + Data([10]))
}

MainActor.assumeIsolated { watchClick() }
