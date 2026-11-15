/// How an input connects, as far as choosing one cares. Ported from Hex's `src/audio/transport.rs` (v3.4.0).
public enum MicrophoneTransport: Sendable {
    /// The internal microphone, switched off while a MacBook's lid is closed. A built-in headphone-jack input is `other`.
    case builtIn
    /// Bluetooth or Bluetooth LE: opening its microphone switches the headset into low-quality call audio.
    case bluetooth
    /// A virtual or aggregate device, such as Microsoft Teams Audio, which may record silence outside its own app,
    /// so it never stands in.
    case virtual
    /// An iPhone microphone offered through Continuity. Opening it prompts on the phone and can fail, so it never
    /// stands in, though a Continuity default or picked microphone is used.
    case continuity
    case other
}

/// An input device as choosing one sees it: its stable UID (what Settings keeps), its name and how it connects.
public struct MicrophoneInput: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let transport: MicrophoneTransport

    public var id: String { uid }

    public init(uid: String, name: String, transport: MicrophoneTransport) {
        self.uid = uid; self.name = name; self.transport = transport
    }
}

/// Whether an input stands in for the picked microphone, and why.
public enum MicrophoneSelection: Equatable, Sendable {
    /// Nothing is picked, or the input is the picked microphone.
    case inUse
    /// The picked microphone is not listed.
    case unlisted
    /// The picked microphone is listed but would not open.
    case unopenable
    /// The picked microphone is built in and off while the lid is closed.
    case lidClosed
}

/// Which input a dictation resolves to, before anything opens.
public enum MicrophoneTarget: Equatable, Sendable {
    /// The picked microphone, by its index in the list.
    case named(Int)
    /// The system's default input.
    case systemDefault
    /// A real input standing in for a default that is the built-in microphone with the lid closed, a passed-over
    /// Bluetooth headset, or missing: the built-in microphone while the lid is open, else the first usable one
    /// listed, never a virtual input or an iPhone's Continuity microphone.
    case standIn(Int)
}

/// The state of the machine an input resolves against.
public struct MicrophoneRoute: Equatable, Sendable {
    /// A MacBook's lid is closed, so its built-in microphone is off.
    public var lidClosed: Bool
    /// System default passes over a Bluetooth default while another real input is listed.
    public var avoidBluetooth: Bool

    public init(lidClosed: Bool = false, avoidBluetooth: Bool = false) {
        self.lidClosed = lidClosed; self.avoidBluetooth = avoidBluetooth
    }
}

public struct MicrophonePlan: Equatable, Sendable {
    public var target: MicrophoneTarget
    public var selection: MicrophoneSelection

    public init(target: MicrophoneTarget, selection: MicrophoneSelection) {
        self.target = target; self.selection = selection
    }
}

/// Why no input resolves.
public enum MicrophoneUnavailable: Error, Equatable, Sendable {
    /// The only microphone is the built-in one, off while the lid is closed.
    case lidClosed
    case noMicrophone
}

/// Which microphone a dictation records from. Ported from Hex's `resolve_input` and `open_selected` in
/// `src/audio.rs` (v3.4.0), with inputs known by UID where Hex knows them by name.
public enum MicrophoneChoice {
    /// An on-demand open retries the picked microphone briefly before falling back, because a device that has
    /// idled for minutes can fail its first open.
    public static let selectedAttempts = 3
    public static let selectedRetryDelay: Duration = .milliseconds(100)

    /// Resolves the input to record from: the picked microphone while it is listed, else the system default. With
    /// the lid closed, the built-in microphone is switched off in hardware though still listed, so it is passed
    /// over. With `avoidBluetooth`, a Bluetooth default is passed over for the built-in microphone, else the first
    /// other real input, and kept only when nothing else is usable. A picked microphone is never passed over for
    /// being Bluetooth. A virtual or aggregate input, or an iPhone's Continuity microphone, never stands in, though
    /// such a default or picked microphone is used as named.
    public static func resolve(selected: String?, inputs: [MicrophoneInput], defaultUID: String?,
                               route: MicrophoneRoute) -> Result<MicrophonePlan, MicrophoneUnavailable> {
        let position = { (uid: String) in inputs.firstIndex { $0.uid == uid } }
        let isBuiltIn = { (index: Int) in inputs[index].transport == .builtIn }
        let avoided = { (index: Int) in route.avoidBluetooth && inputs[index].transport == .bluetooth }
        let off = { (index: Int) in route.lidClosed && isBuiltIn(index) }
        let selection: MicrophoneSelection
        switch selected.map(position) {
        case let .some(.some(index)) where off(index): selection = .lidClosed
        case let .some(.some(index)): return .success(MicrophonePlan(target: .named(index), selection: .inUse))
        case .some(.none): selection = .unlisted
        case .none: selection = .inUse
        }
        let defaultIndex = defaultUID.flatMap(position)
        // A default with no inputs listed is CoreAudio's placeholder, not an input.
        let defaultUsable = !inputs.isEmpty && defaultUID != nil && !(defaultIndex.map(off) ?? false)
        let defaultAvoided = defaultIndex.map(avoided) ?? false
        if defaultUsable, !defaultAvoided { return .success(MicrophonePlan(target: .systemDefault, selection: selection)) }
        // A virtual device or an iPhone's Continuity microphone is used only as the default or by name, never as a
        // stand-in: a virtual one can record silence while its app is idle, and the iPhone prompts and can fail.
        let usable = inputs.indices.filter { !off($0) && ![.virtual, .continuity].contains(inputs[$0].transport) }
        let target: MicrophoneTarget? = usable.first(where: isBuiltIn).map(MicrophoneTarget.standIn)
            ?? usable.first { !avoided($0) }.map(MicrophoneTarget.standIn)
            // A Bluetooth default beats recording nothing.
            ?? (defaultUsable ? .systemDefault : nil)
            ?? usable.first.map(MicrophoneTarget.standIn)
        guard let target else { return .failure(inputs.indices.contains(where: off) ? .lidClosed : .noMicrophone) }
        return .success(MicrophonePlan(target: target, selection: selection))
    }

    /// The input a plan records from.
    public static func input(of plan: MicrophonePlan, in inputs: [MicrophoneInput], defaultUID: String?) -> MicrophoneInput? {
        switch plan.target {
        case let .named(index), let .standIn(index): inputs[index]
        case .systemDefault: inputs.first { $0.uid == defaultUID }
        }
    }

    /// The input System default records from now, for Settings to name.
    public static func systemDefault(inputs: [MicrophoneInput], defaultUID: String?, route: MicrophoneRoute) -> MicrophoneInput? {
        guard case let .success(plan) = resolve(selected: nil, inputs: inputs, defaultUID: defaultUID, route: route) else { return nil }
        return input(of: plan, in: inputs, defaultUID: defaultUID)
    }

    /// Opens the picked microphone, trying `selectedAttempts` times `selectedRetryDelay` apart when `retrying`, and
    /// falls back to `openDefault` once it will not open.
    public static func openSelected<T, Failure: Error>(retrying: Bool, open: () throws(Failure) -> T,
                                                       openDefault: () throws(Failure) -> T,
                                                       sleep: (Duration) -> Void) throws(Failure) -> T {
        let attempts = retrying ? selectedAttempts : 1
        for attempt in 1 ... attempts {
            do { return try open() } catch {
                if attempt < attempts { sleep(selectedRetryDelay) }
            }
        }
        return try openDefault()
    }
}
