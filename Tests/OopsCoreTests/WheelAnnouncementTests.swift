import Testing
@testable import OopsCore

struct WheelAnnouncementTests {
    private func petals(_ places: [(ActionPlace, String)]) -> [WheelPetal] {
        places.map { WheelPetal(place: $0.0, title: $0.1, symbol: nil, width: 0) }
    }

    @Test func `the first ring is read by direction`() {
        let starters = petals([(.up, "Sharpen prompt"), (.right, "Translate"), (.down, "Shorten"), (.left, "Tone")])
        #expect(WheelAnnouncement.opening(starters) == "Actions. Up: Sharpen prompt. Right: Translate. Down: Shorten. Left: Tone.")
    }

    @Test func `a restore petal reads its own title`() {
        #expect(WheelAnnouncement.opening(petals([(.down, "Restore Shorten")])) == "Actions. Down: Restore Shorten.")
    }

    @Test func `diagonals read as two words`() {
        #expect(WheelAnnouncement.opening(petals([(.upRight, "A"), (.downLeft, "B")])) == "Actions. Up right: A. Down left: B.")
    }

    @Test func `no actions say so`() {
        #expect(WheelAnnouncement.opening([]) == "Actions. None saved yet.")
    }

    @Test func `a ring is read by its name`() {
        let languages = petals([(.up, "French"), (.right, "Spanish"), (.down, "German"), (.left, "Italian")])
        #expect(WheelAnnouncement.choices("Language", languages) == "Language. Up: French. Right: Spanish. Down: German. Left: Italian.")
        #expect(WheelAnnouncement.choices("X", []) == "X. No values yet.")
    }
}
