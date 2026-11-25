@testable import Oops
import Testing

@MainActor struct PopoverToggleTests {
    @Test func `presses open and close`() {
        var toggle = PopoverToggle()
        toggle.click = { nil }
        toggle.press()
        #expect(toggle.isPresented)
        toggle.press()
        #expect(!toggle.isPresented)
    }

    @Test func `the click that closed it does not reopen it`() {
        var toggle = PopoverToggle()
        toggle.click = { 7 }
        toggle.press()
        // A second click on the button: its mouse-down closes the popover as a click outside it…
        toggle.click = { 8 }
        toggle.isPresented = false
        // …and its mouse-up, with the same number, presses the button.
        toggle.press()
        #expect(!toggle.isPresented)
        // The next click opens it again.
        toggle.click = { 9 }
        toggle.press()
        #expect(toggle.isPresented)
    }

    @Test func `a click elsewhere leaves the next press alone`() {
        var toggle = PopoverToggle()
        toggle.click = { 1 }
        toggle.press()
        toggle.click = { 2 }
        toggle.isPresented = false
        toggle.click = { 3 }
        toggle.press()
        #expect(toggle.isPresented)
    }

    @Test func `closing without a click remembers nothing`() {
        var toggle = PopoverToggle()
        toggle.click = { nil }
        toggle.press()
        // Escape, a pick in the list, or a page change.
        toggle.isPresented = false
        toggle.press()
        #expect(toggle.isPresented)
    }

    @Test func `an unnumbered click that closed it does not block the next one`() {
        var toggle = PopoverToggle()
        toggle.click = { 0 }
        toggle.press()
        // Closed by a synthetic click elsewhere, then pressed by another: both report 0, and they are not the same click.
        toggle.isPresented = false
        toggle.press()
        #expect(toggle.isPresented)
    }
}
