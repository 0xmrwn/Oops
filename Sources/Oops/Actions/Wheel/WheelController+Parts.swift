import AppKit
import Carbon
import os
import OopsCore

/// The wheel's small parts: petals measured for their names, what VoiceOver hears, its chords as the tap sees them,
/// what it logs of each effect, and its bounded read of the focused field.
extension WheelController {
    /// What VoiceOver hears as the window comes up: the first ring, unless an early arrow has already left it.
    func openingAnnouncement() -> String? {
        guard wheel.level == .root else { return nil }
        let spoken = WheelLayout.ordered(petals.keys).compactMap { place in
            petals[place].map { petal in
                var said = petal
                if place == restoring, let name = wheel.library.action(at: place)?.name { said.title = "Restore \(name)" }
                return said
            }
        }
        return WheelAnnouncement.opening(spoken)
    }

    /// A petal or pill for `title`, measured in the label font, its width kept for the view.
    func petal(_ place: ActionPlace, _ title: String, _ symbol: String?) -> WheelPetal {
        let width = min(WheelLayout.nameLimit, ((title as NSString).size(withAttributes: [.font: Self.font]).width
                + WheelLayout.tracking * Double(title.count)).rounded(.up))
        frame.widths[title] = width
        return WheelPetal(place: place, title: title, symbol: symbol, width: width)
    }

    func announce(_ text: String) {
        log(["wheel": "announce", "text": text])
        NSAccessibility.post(element: panel.window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func log(_ entry: [String: String]) {
        #if DEBUG
        onEvent?(entry)
        #endif
    }

    static let font = NSFont.systemFont(ofSize: WheelLayout.labelSize, weight: .medium)
    /// Slow motion for frame-by-frame captures.
    static var pace: Double { DebugFlags.wheelSlow ? 0.25 : 1 }
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || EyesDropView.forced.contains("reduce-motion")
    }

    /// A shortcut as the tap sees its key: Carbon's modifiers as event flags.
    static func chord(_ shortcut: Shortcut) -> WheelChord {
        var flags: CGEventFlags = []
        if shortcut.modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if shortcut.modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return WheelChord(keyCode: Int64(shortcut.keyCode), flags: flags)
    }

    static func entry(_ effect: WheelEffect) -> [String: String] {
        func list(_ places: [ActionPlace]) -> String { places.map(\.rawValue).joined(separator: ",") }
        return switch effect {
        case let .bloom(places): ["wheel": "bloom", "places": list(places)]
        case .skipBloom: ["wheel": "skipBloom"]
        case let .point(place): ["wheel": "point", "place": place?.rawValue ?? ""]
        case .showNames: ["wheel": "showNames"]
        case let .select(place, symbol): ["wheel": "select", "place": place.rawValue, "symbol": symbol]
        case let .bloomChoices(places): ["wheel": "bloomChoices", "places": list(places)]
        case let .run(invocation): ["wheel": "run", "invocation": ActionSession.name(invocation) + (Self.value(invocation).map { "/" + $0 } ?? "")]
        case .restore: ["wheel": "restore"]
        case .close: ["wheel": "close"]
        }
    }

    private static func value(_ invocation: ActionInvocation) -> String? {
        if case let .saved(_, value) = invocation { value } else { nil }
    }

    /// Where the field is and how its text is coloured.
    struct Spot: Sendable {
        var geometry: CapsulePlacement.Geometry, style: CaretStyle?
    }

    /// `read`'s answer, or nil once `limit` passes: an editor slow to answer never holds the wheel back. The read
    /// is cancelled when it loses the race or the caller goes, so its retries stop instead of holding up the editor
    /// Fix and Actions read through.
    static func reading<T: Sendable>(within limit: Duration, _ read: @escaping @Sendable () async -> T?) async -> T? {
        let reading = Task { await read() }
        let answer = Answer<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answer.wait(continuation)
                Task { answer.give(await reading.value) }
                Task {
                    try? await Task.sleep(for: limit)
                    reading.cancel()
                    answer.give(nil)
                }
            }
        } onCancel: {
            reading.cancel()
            answer.give(nil)
        }
    }

    /// The first answer given, kept for a waiter that comes after it.
    final class Answer<T: Sendable>: Sendable {
        private struct State { var waiter: CheckedContinuation<T?, Never>?, given: T??, done = false }
        private let state = OSAllocatedUnfairLock(initialState: State(waiter: nil, given: nil))

        func wait(_ continuation: CheckedContinuation<T?, Never>) {
            let given: T?? = state.withLock { state in
                guard let given = state.given, !state.done else { state.waiter = continuation; return nil }
                state.done = true
                return given
            }
            if let given { continuation.resume(returning: given) }
        }

        func give(_ value: T?) {
            let waiter: CheckedContinuation<T?, Never>? = state.withLock { state in
                guard state.given == nil else { return nil }
                state.given = .some(value)
                guard let waiter = state.waiter else { return nil }
                state.waiter = nil
                state.done = true
                return waiter
            }
            waiter?.resume(returning: value)
        }
    }
}
