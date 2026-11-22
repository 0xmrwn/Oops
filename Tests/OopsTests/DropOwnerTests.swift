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

    @Test func `a hold waits for another feature's drop`() {
        let drop = DropOwner()
        #expect(drop.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        #expect(!drop.hold(.actions, busy: { true }))
        #expect(drop.holder == .fix)
    }

    @Test func `a hold keeps the others out until it ends`() {
        let drop = DropOwner()
        var open = true
        #expect(drop.hold(.actions, busy: { open }))
        #expect(drop.holder == .actions)
        #expect(!drop.claim(.fix, busy: { false }) { AnyView(EmptyView()) })
        open = false
        #expect(drop.holder == nil)
        #expect(drop.claim(.fix, busy: { false }) { AnyView(EmptyView()) })
    }

    @Test func `an agent that yields lets Fix claim at once`() {
        let drop = DropOwner()
        #expect(drop.claim(.agent, busy: { true }) { AnyView(EmptyView()) })
        #expect(!drop.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        drop.yield(.agent)
        #expect(drop.holder == nil)
        #expect(drop.claimant == nil)
        #expect(drop.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        #expect(drop.holder == .fix)
    }

    @Test func `yielding leaves another feature's claim alone`() {
        let drop = DropOwner()
        #expect(drop.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        drop.yield(.agent)
        #expect(drop.holder == .fix)
    }

    @Test func `an agent whose person left lets Fix claim`() {
        let drop = DropOwner()
        var inField = true
        #expect(drop.claim(.agent, busy: { inField }) { AnyView(EmptyView()) })
        #expect(!drop.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        inField = false
        #expect(drop.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
    }

    @Test func `a claim takes away what an agent's ready drop opened`() {
        let drop = DropOwner()
        #expect(drop.claim(.agent, busy: { false }) { AnyView(EmptyView()) })
        drop.panel.model.open = {}; drop.panel.model.narrates = true
        #expect(drop.claim(.fix, busy: { false }) { AnyView(EmptyView()) })
        #expect(drop.panel.model.open == nil)
        #expect(!drop.panel.model.narrates, "Fix's working drop shows its eyes only")
    }

    @Test func `the drop going away is reported once it has let go`() async {
        let drop = DropOwner()
        var idle = 0
        drop.onIdle = { idle += 1 }
        drop.panel.hide()
        #expect(idle == 0, "not while the hide is still under way")
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(idle == 1)
    }

    @Test func `a hold is refused while the same feature's drop is at work`() {
        let drop = DropOwner()
        #expect(drop.claim(.actions, busy: { true }) { AnyView(EmptyView()) })
        #expect(!drop.hold(.actions, busy: { true }))
    }
}
