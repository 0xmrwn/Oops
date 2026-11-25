import AppKit

/// Whether a button's popover shows, so that a second click on the button closes it. A popover closes on the
/// mouse-down of a click outside it and the button acts on that click's mouse-up: left alone, the one click closed the
/// popover and opened it again. A mouse-up carries its mouse-down's event number, so the press from the click that
/// has just closed the popover is skipped; no time window, and a click anywhere else leaves the next press alone.
@MainActor struct PopoverToggle {
    var isPresented = false {
        // A synthetic click can carry no number (0): it identifies nothing, so it never matches a later one.
        didSet { if oldValue, !isPresented { closedBy = click().flatMap { $0 == 0 ? nil : $0 } } }
    }

    /// The number of the left click being handled, if any. The tests stand in for the event queue.
    var click: @MainActor () -> Int? = { PopoverToggle.currentClick }
    private var closedBy: Int?

    /// The button's action: opens the popover, or closes it, unless this very click has just closed it.
    mutating func press() {
        let skip = closedBy != nil && click() == closedBy
        closedBy = nil
        if !skip { isPresented.toggle() }
    }

    private static var currentClick: Int? {
        // `eventNumber` is defined for mouse events only.
        guard let event = NSApp?.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp else { return nil }
        return event.eventNumber
    }
}
