#if DEBUG
import AppKit
import ApplicationServices

/// Compatibility runs only: what happens to the field in front when a key panel of Oops's takes the keys for a moment
/// and gives them back, which decides where the Actions wheel's centre may take typing.
extension AppProbe {
    struct FocusTrip: Codable {
        var frontBefore, frontDuring, frontAfter: String?
        /// The same element has focus after as before.
        var sameElement: Bool
        var selectionBefore, selectionAfter: [Int]?
        var valueSame: Bool
        /// The panel became key while the app stayed in front.
        var panelWasKey: Bool
        /// A key posted at the HID level while the panel was key landed in its field.
        var keysReachedPanel: Bool
        /// The field's text after a marker character was typed into it once the panel had gone.
        var typedAfter: String?
        /// That character replaced the selection the field had before.
        var landedAtSelection: Bool
        /// With refocus: whether setting focus and the selection back restored both.
        var refocused: Bool?
    }

    /// The focus trip's own draft: `write` types short text over the field's whole text, as keys and never through
    /// the clipboard; `select` sets "location,length"; `clear` empties the field only while it is the element written
    /// into and its whole text is one of the probe's values ("element<tab>value<tab>value…").
    static func scratch(_ action: String, _ text: String, _ editor: EditorAccess) throws {
        guard let element = try? editor.focused() else { throw Failure("no field") }
        let value = editor.attribute(element, kAXValueAttribute) as? String ?? ""
        let whole = NSRange(location: 0, length: (value as NSString).length)
        switch action {
        case "write":
            if whole.length > 0 { _ = editor.setRange(element, whole) }
            guard KeyboardGate.postText(text) else { throw Failure("text too long to type as keys") }
        case "select":
            let parts = text.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2 else { throw Failure("no selection") }
            _ = editor.setRange(element, NSRange(location: parts[0], length: parts[1]))
        case "clear":
            let parts = text.components(separatedBy: "\t")
            guard let expected = parts.first.flatMap(Int.init), Self.matches(element, expected, value, Set(parts.dropFirst())) else {
                throw Failure("not the probe's draft: left as it is")
            }
            _ = editor.setRange(element, whole)
            KeyboardGate.postKey(51, flags: [])
        default: throw Failure("unknown action \(action)")
        }
    }

    /// The field written into, holding exactly one of the probe's values.
    static func matches(_ element: AXUIElement, _ expected: Int, _ value: String, _ values: Set<String>) -> Bool {
        Int(bitPattern: UInt(CFHash(element))) == expected && values.contains(value.trimmingCharacters(in: .newlines))
    }

    private final class TripPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<FocusTrip, Error>?
    }

    /// From the probe's queue, which waits: the panel's work runs on the main thread while its event loop keeps
    /// going, so the panel can become key and keys can reach it.
    static func focusTrip(_ editor: EditorAccess, refocus: Bool) throws -> FocusTrip {
        let done = DispatchSemaphore(value: 0), outcome = Outcome()
        Task { @MainActor in
            do { outcome.result = .success(try await trip(editor, refocus: refocus)) } catch { outcome.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try outcome.result!.get()
    }

    @MainActor private static func trip(_ editor: EditorAccess, refocus: Bool) async throws -> FocusTrip {
        func front() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        func value(_ element: AXUIElement) -> String? { editor.attribute(element, kAXValueAttribute) as? String }
        func spin(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        guard let element = try? editor.focused(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw Failure("no field")
        }
        let frontBefore = front(), before = value(element), selection = editor.range(element)
        let panel = TripPanel(contentRect: CGRect(x: 200, y: 200, width: 240, height: 34), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 34))
        panel.contentView = field
        panel.orderFrontRegardless(); panel.makeKey(); panel.makeFirstResponder(field)
        await spin(0.15)
        let frontDuring = front(), wasKey = panel.isKeyWindow
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            let units = Array("q".utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
        await spin(0.1)
        let reached = field.stringValue == "q"
        panel.orderOut(nil)
        await spin(0.2)
        let after = try? editor.focused(), selectionAfter = editor.range(element), valueAfter = value(element)
        var refocused: Bool?
        if refocus, let selection { refocused = editor.refocus(element: element, pid: pid, selection: selection) }
        _ = KeyboardGate.postText("§")
        await spin(0.2)
        let typed = value(element)
        let wanted = selection.flatMap { range in before.map { ($0 as NSString).replacingCharacters(in: range, with: "§") } }
        return FocusTrip(frontBefore: frontBefore, frontDuring: frontDuring, frontAfter: front(),
                         sameElement: after.map { CFEqual($0, element) } ?? false,
                         selectionBefore: selection.map { [$0.location, $0.length] }, selectionAfter: selectionAfter.map { [$0.location, $0.length] },
                         valueSame: valueAfter == before, panelWasKey: wasKey, keysReachedPanel: reached,
                         typedAfter: typed, landedAtSelection: wanted != nil && typed == wanted, refocused: refocused)
    }
}
#endif
