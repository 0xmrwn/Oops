import Foundation
@testable import Oops
import OopsCore
import Testing

/// Keyboard model switching with a clock and input sources the test drives.
@MainActor struct KeyboardModelDriverTests {
    private static let abc = "com.apple.keylayout.ABC", russian = "com.apple.keylayout.Russian", french = "com.apple.keylayout.French"
    private static let whisperRU = KeyboardModelChoice(modelID: "whisper_large_v3_turbo", language: "ru")

    /// A driver listening to `sources`, with `installed` models, recording what it applied.
    @MainActor private final class Run {
        let clock = ManualClock()
        let sources: AsyncStream<String?>.Continuation
        let driver: KeyboardModelDriver
        var applied: [KeyboardModelChoice] = []
        var installed: Set<String> = ["whisper_large_v3_turbo"]

        init(mappings: [String: KeyboardModelChoice] = [russian: whisperRU]) {
            let (stream, continuation) = AsyncStream.makeStream(of: String?.self)
            sources = continuation
            let clock = clock
            driver = KeyboardModelDriver(defaults: nil, sources: { stream }, now: { clock.now }, sleep: { await clock.sleep($0) })
            driver.isInstalled = { [weak self] in self?.installed.contains($0) == true }
            driver.apply = { [weak self] in self?.applied.append($0) }
            for (source, choice) in mappings { driver.setMapping(choice, for: source) }
            driver.start()
        }

        /// The source becomes `id`, and its report has been read.
        func select(_ id: String) async {
            // Timers started by earlier work (a mapping being set) have begun their sleep first.
            for _ in 0..<20 { await Task.yield() }
            let waiting = clock.sleepers
            sources.yield(id)
            _ = await eventually { clock.sleepers > waiting }
        }
    }

    @Test func `a mapped source applies its model once the debounce has passed`() async {
        let run = Run()
        await run.select(Self.russian)
        run.clock.advance(by: .milliseconds(299))
        await settle()
        #expect(run.applied.isEmpty)
        run.clock.advance(by: .milliseconds(1))
        #expect(await eventually { run.applied == [Self.whisperRU] })
    }

    @Test func `only the last of quick changes applies`() async {
        let run = Run(mappings: [Self.russian: Self.whisperRU, Self.french: KeyboardModelChoice(modelID: "whisper_large_v3_turbo", language: "fr")])
        await run.select(Self.russian)
        run.clock.advance(by: .milliseconds(100))
        await run.select(Self.french)
        run.clock.advance(by: .milliseconds(300))
        #expect(await eventually { run.applied.count == 1 })
        await settle()
        #expect(run.applied.map(\.language) == ["fr"])
    }

    @Test func `a manual choice wins until the source changes again`() async {
        let run = Run()
        await run.select(Self.russian)
        run.driver.manualChoice()
        run.clock.advance(by: .seconds(1))
        await settle()
        #expect(run.applied.isEmpty)
        await run.select(Self.abc)
        await run.select(Self.russian)
        run.clock.advance(by: .milliseconds(300))
        #expect(await eventually { run.applied == [Self.whisperRU] })
    }

    @Test func `an unmapped source and a model no longer installed change nothing`() async {
        let run = Run()
        run.installed = []
        await run.select(Self.abc)
        run.clock.advance(by: .seconds(1))
        await run.select(Self.russian)
        run.clock.advance(by: .seconds(1))
        await settle()
        #expect(run.applied.isEmpty)
    }

    @Test func `it listens only while a mapping exists, and keeps its mappings`() throws {
        let name = "oops-keyboard-models-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let driver = KeyboardModelDriver(defaults: defaults, sources: { AsyncStream { _ in } })
        driver.start()
        #expect(!driver.isListening)
        driver.setMapping(Self.whisperRU, for: Self.russian)
        #expect(driver.isListening)
        let reloaded = KeyboardModelDriver(defaults: defaults, sources: { AsyncStream { _ in } })
        #expect(reloaded.settings == KeyboardModelSwitchSettings(enabled: true, mappings: [Self.russian: Self.whisperRU]))
        driver.setMapping(nil, for: Self.russian)
        #expect(!driver.isListening)
        #expect(!driver.settings.enabled)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

/// Time that passes only when the test says so; sleepers wake once their deadline is reached.
@MainActor final class ManualClock {
    private(set) var now = ContinuousClock.now
    private var waiting: [(deadline: ContinuousClock.Instant, wake: CheckedContinuation<Void, Never>)] = []
    /// How many sleeps have started, woken or not.
    private(set) var sleepers = 0

    func sleep(_ duration: Duration) async {
        sleepers += 1
        let deadline = now + duration
        await withCheckedContinuation { waiting.append((deadline, $0)) }
    }

    func advance(by duration: Duration) {
        now += duration
        let due = waiting.filter { $0.deadline <= now }
        waiting.removeAll { $0.deadline <= now }
        due.forEach { $0.wake.resume() }
    }
}
