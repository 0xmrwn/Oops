import Foundation
@testable import Oops
import OopsCore
import Testing

/// What the wheel remembers of its typing cue: an open counts once its words have shown, and typing ends it.
@MainActor struct WheelCueStoreTests {
    private func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: "wheel-cue-\(UUID())")) }

    @Test func `only opens whose words showed are counted, up to five`() throws {
        let defaults = try defaults()
        for _ in 0 ..< 10 { #expect(WheelController.teachesTyping(defaults)) }
        #expect(defaults.integer(forKey: WheelController.cueOpensKey) == 0, "deciding costs nothing")
        for _ in 0 ..< 4 { WheelController.countCueOpen(defaults) }
        #expect(WheelController.teachesTyping(defaults))
        WheelController.countCueOpen(defaults)
        #expect(!WheelController.teachesTyping(defaults))
    }

    @Test func `a typed instruction ends it`() throws {
        let defaults = try defaults()
        WheelController.learnedTyping(defaults)
        #expect(!WheelController.teachesTyping(defaults))
    }
}
