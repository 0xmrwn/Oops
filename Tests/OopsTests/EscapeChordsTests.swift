@testable import Oops
import Testing

/// Escape shared between Dictate and an agent run: Dictate keeps exactly the chords it asks for, and its press.
struct EscapeChordsTests {
    @Test func `dictate alone registers exactly its own chords`() {
        var escapes = EscapeChords()
        #expect(escapes.arm(.dictate, [0, 256]) == [0, 256])
        #expect(escapes.target == .dictate)
        #expect(escapes.arm(.dictate, []).isEmpty)
    }

    @Test func `an agent run adds plain Escape and takes the press only while Dictate hasn't armed it`() {
        var escapes = EscapeChords()
        #expect(escapes.arm(.agent, [0]) == [0])
        #expect(escapes.target == .agent)
        #expect(escapes.arm(.dictate, [0, 256]) == [0, 256])
        #expect(escapes.target == .dictate)
        #expect(escapes.arm(.dictate, []) == [0])
        #expect(escapes.target == .agent)
        #expect(escapes.arm(.agent, []).isEmpty)
        #expect(escapes.target == .dictate)
    }
}
