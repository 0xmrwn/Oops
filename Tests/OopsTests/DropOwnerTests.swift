import SwiftUI
@testable import Oops
import Testing

@MainActor struct DropOwnerTests {
    private static let other = DropFeature(name: "other")

    @Test func `a request while fix holds the drop is refused and leaves it alone`() {
        let drop = DropOwner()
        var fixBusy = true, built: [String] = []
        #expect(drop.claim(.fix, busy: { fixBusy }) { built.append("fix"); return AnyView(EmptyView()) })
        #expect(drop.holder == .fix)

        #expect(!drop.claim(Self.other, busy: { true }) { built.append("other"); return AnyView(EmptyView()) })
        #expect(drop.holder == .fix)
        #expect(built == ["fix"], "the refused feature's view was never built or shown")

        // Fix asks again while it holds the drop: granted, with the view it already has.
        #expect(drop.claim(.fix, busy: { fixBusy }) { built.append("fix"); return AnyView(EmptyView()) })
        #expect(built == ["fix"])

        // Fix is done and its drop is gone: the drop is free.
        fixBusy = false
        #expect(drop.holder == nil)
        #expect(drop.claim(Self.other, busy: { true }) { built.append("other"); return AnyView(EmptyView()) })
        #expect(drop.holder == Self.other)
        #expect(built == ["fix", "other"])
        #expect(!drop.claim(.fix, busy: { false }) { built.append("fix"); return AnyView(EmptyView()) })
    }
}
