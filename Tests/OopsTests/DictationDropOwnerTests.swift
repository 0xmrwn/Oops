@testable import Oops
import CoreGraphics
import OopsCore
import SwiftUI
import Testing

/// The dictation drop in the shared panel: where it is placed, and so where live words at the caret go.
@MainActor struct DictationDropOwnerTests {
    @Test func `a recording that starts while the last dictation's drop is up locates the field again`() async throws {
        let owner = DropOwner()
        defer { owner.panel.hide() }
        var located = 0
        let drop = DictationDropOwner(owner: owner) {
            located += 1
            return (CapsulePlacement.Geometry(element: CGRect(x: 100, y: 200, width: 600, height: 300),
                                              caret: CGRect(x: 120 + CGFloat(located) * 100, y: 210, width: 1, height: 17)), nil)
        }
        #expect(drop.claim(busy: { true }))
        drop.show(.recording)
        try await until { owner.panel.isShown }
        drop.show(.transcribing)
        #expect(located == 1, "a state within the dictation keeps the drop's spot")

        // The next press comes while the first is transcribed: the drop never left, but its text moved the caret.
        #expect(drop.claim(busy: { true }))
        drop.show(.recording)
        try await until { located == 2 }
    }

    @Test func `fix takes over a written or kept drop but never a recording`() async throws {
        let offer = DropAction(symbol: "wand.and.sparkles", label: "Clean up with AI") {}
        for state in [DictationDropState.written, .kept] {
            let owner = DropOwner()
            defer { owner.panel.hide() }
            let drop = DictationDropOwner(owner: owner) { nil }
            var busy = true
            #expect(drop.claim(busy: { busy }))
            drop.show(.recording)
            try await until { owner.panel.isShown }
            #expect(!fix(owner), "a recording is the dictation's alone")
            busy = false
            drop.show(state, action: offer)
            #expect(owner.holder == nil, "\(state) only offers its button")
            #expect(fix(owner))
            #expect(owner.holder == .fix)
            #expect(!drop.claim(busy: { false }), "Fix's own drop is up now")
        }
    }

    private func fix(_ owner: DropOwner) -> Bool {
        owner.claim(.fix, busy: { false }) { AnyView(EmptyView()) }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
