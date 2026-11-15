@testable import OopsCore
import Testing

/// Hex's tests of `resolve_input` (`src/audio.rs` at v3.4.0), under their upstream names. Hex knows inputs by name
/// and these use each name as its UID too. Hex's own virtual microphone and `--device` have no counterpart here, so
/// the asserts about them are left out, and a default Hex Microphone reads as no default.
struct MicrophoneChoiceHexTests {
    static let open = MicrophoneRoute(lidClosed: false, avoidBluetooth: false)
    static let closed = MicrophoneRoute(lidClosed: true, avoidBluetooth: false)
    static let avoid = MicrophoneRoute(lidClosed: false, avoidBluetooth: true)

    @Test func `a headphone jack microphone is used with the lid closed`() {
        // The jack input reads as other, so only the internal one is off.
        let names = microphones(("MacBook Pro Microphone", .builtIn), ("External Microphone", .other))
        let plan = { (selected: String?, defaultUID: String?) in
            MicrophoneChoice.resolve(selected: selected, inputs: names, defaultUID: defaultUID, route: Self.closed)
        }
        #expect(plan(nil, "External Microphone") == found(.systemDefault))
        #expect(plan("External Microphone", "MacBook Pro Microphone") == found(.named(1)))
        #expect(plan(nil, "MacBook Pro Microphone") == found(.standIn(1)))
    }

    @Test func `system default passes over a bluetooth default`() {
        let names = microphones(("AirPods Pro", .bluetooth), ("MacBook Pro Microphone", .builtIn), ("USB Mic", .other))
        let plan = { (selected: String?, defaultUID: String?, route: MicrophoneRoute) in
            MicrophoneChoice.resolve(selected: selected, inputs: names, defaultUID: defaultUID, route: route)
        }
        // A Bluetooth default stands in with the built-in microphone.
        #expect(plan(nil, "AirPods Pro", Self.avoid) == found(.standIn(1)))
        // A missing picked microphone falls back the same way.
        #expect(plan("Gone", "AirPods Pro", Self.avoid) == found(.standIn(1), .unlisted))
        // A picked Bluetooth microphone is honoured.
        #expect(plan("AirPods Pro", "USB Mic", Self.avoid) == found(.named(0)))
        // Other defaults are followed.
        #expect(plan(nil, "USB Mic", Self.avoid) == found(.systemDefault))
        // With the setting off, System default follows the Bluetooth default.
        #expect(plan(nil, "AirPods Pro", Self.open) == found(.systemDefault))
        // With the lid closed, the next real input stands in.
        #expect(plan(nil, "AirPods Pro", MicrophoneRoute(lidClosed: true, avoidBluetooth: true)) == found(.standIn(2)))
        // No default prefers a wired input to Bluetooth too.
        let noBuiltIn = microphones(("AirPods Pro", .bluetooth), ("USB Mic", .other))
        #expect(MicrophoneChoice.resolve(selected: nil, inputs: noBuiltIn, defaultUID: nil, route: Self.avoid) == found(.standIn(1)))
    }

    @Test func `a bluetooth default is kept when nothing else is usable`() {
        let onlyBluetooth = microphones(("AirPods Pro", .bluetooth), ("Beats", .bluetooth))
        #expect(MicrophoneChoice.resolve(selected: nil, inputs: onlyBluetooth, defaultUID: "AirPods Pro", route: Self.avoid)
            == found(.systemDefault))
        // With the lid closed the built-in microphone is no alternative.
        let lid = microphones(("AirPods Pro", .bluetooth), ("MacBook Pro Microphone", .builtIn))
        #expect(MicrophoneChoice.resolve(selected: nil, inputs: lid, defaultUID: "AirPods Pro",
                                         route: MicrophoneRoute(lidClosed: true, avoidBluetooth: true)) == found(.systemDefault))
    }

    @Test func `a virtual input never stands in`() {
        let resolve = { (selected: String?, inputs: [MicrophoneInput], defaultUID: String?, route: MicrophoneRoute) in
            MicrophoneChoice.resolve(selected: selected, inputs: inputs, defaultUID: defaultUID, route: route)
        }
        // Lid closed, only the built-in microphone and Teams: say why.
        let lid = microphones(("MacBook Pro Microphone", .builtIn), ("Microsoft Teams Audio", .virtual))
        #expect(resolve(nil, lid, "MacBook Pro Microphone", Self.closed) == .failure(.lidClosed))
        // A real input still stands in ahead of it.
        let withUSB = microphones(("MacBook Pro Microphone", .builtIn), ("Microsoft Teams Audio", .virtual), ("USB Mic", .other))
        #expect(resolve(nil, withUSB, "MacBook Pro Microphone", Self.closed) == found(.standIn(2)))
        // A Bluetooth default is kept rather than passed over for Teams.
        let headset = microphones(("Microsoft Teams Audio", .virtual), ("AirPods Pro", .bluetooth))
        #expect(resolve(nil, headset, "AirPods Pro", Self.avoid) == found(.systemDefault))
        // Only virtual inputs and no default: nothing to record from.
        let virtualOnly = microphones(("Loopback Audio", .virtual), ("Microsoft Teams Audio", .virtual))
        #expect(resolve(nil, virtualOnly, nil, Self.open) == .failure(.noMicrophone))
        // A virtual default or picked microphone is used as named.
        #expect(resolve(nil, headset, "Microsoft Teams Audio", Self.open) == found(.systemDefault))
        #expect(resolve("Microsoft Teams Audio", headset, "AirPods Pro", Self.open) == found(.named(0)))
    }

    @Test func `an iphone microphone never stands in`() {
        let resolve = { (selected: String?, inputs: [MicrophoneInput], defaultUID: String?, route: MicrophoneRoute) in
            MicrophoneChoice.resolve(selected: selected, inputs: inputs, defaultUID: defaultUID, route: route)
        }
        // Lid closed, only the built-in microphone and the iPhone: say why.
        let lid = microphones(("MacBook Pro Microphone", .builtIn), ("iPhone Microphone", .continuity))
        #expect(resolve(nil, lid, "MacBook Pro Microphone", Self.closed) == .failure(.lidClosed))
        // A Bluetooth default is kept rather than passed over for the iPhone.
        let headset = microphones(("iPhone Microphone", .continuity), ("AirPods Pro", .bluetooth))
        #expect(resolve(nil, headset, "AirPods Pro", Self.avoid) == found(.systemDefault))
        // An iPhone default or picked microphone is used as named.
        #expect(resolve(nil, headset, "iPhone Microphone", Self.open) == found(.systemDefault))
        #expect(resolve("iPhone Microphone", headset, "AirPods Pro", Self.open) == found(.named(0)))
    }

    @Test func `inputs resolve to the selection then the system default`() {
        let names = microphones(("KIT PODS", .other), ("MacBook Pro Microphone", .builtIn), ("USB Mic", .other))
        let plan = { (selected: String?, defaultUID: String?) in
            MicrophoneChoice.resolve(selected: selected, inputs: names, defaultUID: defaultUID, route: Self.open)
        }
        // A listed picked microphone wins over the default.
        #expect(plan("USB Mic", "KIT PODS") == found(.named(2)))
        // System default follows the OS default, even a Bluetooth headset.
        #expect(plan(nil, "KIT PODS") == found(.systemDefault))
        // A missing picked microphone stands in with the default.
        #expect(plan("Studio Display Microphone", "KIT PODS") == found(.systemDefault, .unlisted))
        // Without a default, the built-in microphone stands in.
        #expect(plan(nil, nil) == found(.standIn(1)))
        #expect(plan("Gone", nil) == found(.standIn(1), .unlisted))
        // Without a built-in microphone or any default, the first real input stands in.
        let others = microphones(("KIT PODS", .other), ("USB Mic", .other))
        #expect(MicrophoneChoice.resolve(selected: nil, inputs: others, defaultUID: nil, route: Self.open) == found(.standIn(0)))
        // No inputs at all.
        #expect(MicrophoneChoice.resolve(selected: "USB Mic", inputs: [], defaultUID: nil, route: Self.open) == .failure(.noMicrophone))
        #expect(MicrophoneChoice.resolve(selected: nil, inputs: [], defaultUID: "Default Audio Device", route: Self.open)
            == .failure(.noMicrophone))
    }

    @Test func `a closed lid passes over the built in microphone`() {
        let names = microphones(("MacBook Pro Microphone", .builtIn), ("Studio Display Microphone", .other), ("USB Mic", .other))
        let closed = { (selected: String?, defaultUID: String?) in
            MicrophoneChoice.resolve(selected: selected, inputs: names, defaultUID: defaultUID, route: Self.closed)
        }
        // A built-in default stands in with the first other real input.
        #expect(closed(nil, "MacBook Pro Microphone") == found(.standIn(1)))
        // So does a missing default: never the built-in.
        #expect(closed(nil, nil) == found(.standIn(1)))
        // Another default is still followed.
        #expect(closed(nil, "USB Mic") == found(.systemDefault))
        // A picked built-in microphone stands aside for the default.
        #expect(closed("MacBook Pro Microphone", "USB Mic") == found(.systemDefault, .lidClosed))
        #expect(closed("MacBook Pro Microphone", "MacBook Pro Microphone") == found(.standIn(1), .lidClosed))
        // Other picked microphones are unaffected.
        #expect(closed("USB Mic", "MacBook Pro Microphone") == found(.named(2)))
        // With the lid open the built-in microphone is used as before.
        #expect(MicrophoneChoice.resolve(selected: nil, inputs: names, defaultUID: "MacBook Pro Microphone", route: Self.open)
            == found(.systemDefault))
        // With nothing else to use, say why rather than record silence.
        let onlyBuiltIn = microphones(("MacBook Pro Microphone", .builtIn))
        for defaultUID in ["MacBook Pro Microphone", nil] {
            #expect(MicrophoneChoice.resolve(selected: nil, inputs: onlyBuiltIn, defaultUID: defaultUID, route: Self.closed)
                == .failure(.lidClosed))
        }
        #expect(MicrophoneChoice.resolve(selected: "MacBook Pro Microphone", inputs: onlyBuiltIn,
                                         defaultUID: "MacBook Pro Microphone", route: Self.closed) == .failure(.lidClosed))
    }

    @Test func `cold open retries the selected microphone before falling back`() {
        struct Waking: Error {}
        func open(retrying: Bool, failures: Int) -> (String, Int, Int) {
            var attempts = 0, sleeps = 0
            let result = try? MicrophoneChoice.openSelected(retrying: retrying, open: { () throws(Waking) -> String in
                attempts += 1
                guard attempts > failures else { throw Waking() }
                return "selected"
            }, openDefault: { () throws(Waking) -> String in "automatic" }, sleep: { _ in sleeps += 1 })
            return (result ?? "failed", attempts, sleeps)
        }
        #expect(open(retrying: true, failures: 2) == ("selected", 3, 2))
        #expect(open(retrying: true, failures: 3) == ("automatic", 3, 2))
        #expect(open(retrying: false, failures: 1) == ("automatic", 1, 0))
    }
}

func microphones(_ list: (String, MicrophoneTransport)...) -> [MicrophoneInput] {
    list.map { MicrophoneInput(uid: $0.0, name: $0.0, transport: $0.1) }
}

private func found(_ target: MicrophoneTarget, _ selection: MicrophoneSelection = .inUse) -> Result<MicrophonePlan, MicrophoneUnavailable> {
    .success(MicrophonePlan(target: target, selection: selection))
}
