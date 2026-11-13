import Foundation
@testable import Oops
import OopsCore
import Testing

/// The On this Mac rows' states, against a store the test drives.
@MainActor struct LocalModelsTests {
    private let parakeet = SpeechModelCatalog.model(id: "parakeet_unified_en")!
    private var file: String { parakeet.artifact.fileName }

    @Test func `a download goes through progress and verifying to installed`() async {
        let store = FakeModelStore()
        let local = LocalModels(store: store)
        #expect(local.state(parakeet) == .notInstalled)
        local.download(parakeet)
        #expect(local.state(parakeet) == .downloading(0))
        #expect(await eventually { store.downloads == [file] })
        store.send(file, .downloading, fraction: 0.4)
        #expect(await eventually { local.state(parakeet) == .downloading(0.4) })
        store.send(file, .verifying, fraction: 1)
        #expect(await eventually { local.state(parakeet) == .verifying })
        store.install(file)
        #expect(await eventually { local.state(parakeet) == .installed })
        #expect(local.fileURL(parakeet.id) == FakeModelStore.url(file))
        #expect(local.installed.map(\.id) == [parakeet.id])
    }

    @Test func `cancel shows Download again and the next download asks the store again`() async {
        let store = FakeModelStore()
        let local = LocalModels(store: store)
        local.download(parakeet)
        #expect(await eventually { store.downloads.count == 1 })
        store.send(file, .downloading, fraction: 0.4)
        local.cancel(parakeet)
        #expect(local.state(parakeet) == .notInstalled)
        #expect(await eventually { store.cancelled == [file] })
        // Pressed again at once, while the cancelled download winds down: it starts once that one has ended. The
        // store keeps the partial file; resuming from it is the store's part.
        local.download(parakeet)
        #expect(local.state(parakeet) == .downloading(0))
        #expect(await eventually { store.downloads.count == 2 })
        #expect(local.state(parakeet) == .downloading(0))
        store.install(file)
        #expect(await eventually { local.state(parakeet) == .installed })
    }

    @Test func `a failure stays on the row in a short line until the person acts`() async {
        let store = FakeModelStore()
        let local = LocalModels(store: store)
        local.download(parakeet)
        #expect(await eventually { store.downloads.count == 1 })
        store.fail(file, .network("The request timed out after 60 seconds on a very slow link"))
        #expect(await eventually { local.state(parakeet) == .failed("Couldn’t connect. Try again.") })
        await local.refresh()
        #expect(local.state(parakeet) == .failed("Couldn’t connect. Try again."))
        local.download(parakeet)
        #expect(local.state(parakeet) == .downloading(0))
    }

    @Test func `refresh reads what is installed and nothing downloads by itself`() async {
        let store = FakeModelStore(installed: [file])
        let local = LocalModels(store: store)
        await local.refresh()
        #expect(local.state(parakeet) == .installed)
        #expect(local.state(SpeechModelCatalog.model(id: "parakeet_v3")!) == .notInstalled)
        #expect(store.downloads.isEmpty)
    }

    @Test func `delete removes the file, or says why it couldn't`() async {
        let store = FakeModelStore(installed: [file])
        let local = LocalModels(store: store)
        await local.refresh()
        #expect(await local.delete(parakeet))
        #expect(local.state(parakeet) == .notInstalled)
        #expect(local.fileURL(parakeet.id) == nil)

        let stuck = FakeModelStore(installed: [file])
        stuck.failDeletes()
        let other = LocalModels(store: stuck)
        await other.refresh()
        #expect(await other.delete(parakeet) == false)
        #expect(other.state(parakeet) == .failed("Couldn’t delete the model."))
    }
}
