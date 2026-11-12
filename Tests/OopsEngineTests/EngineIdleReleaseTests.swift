@testable import OopsCore
@testable import OopsEngine
import Synchronization
import XCTest

/// The idle release without a model or real time: a stand-in model, and sleeps that end when the test says.
final class EngineIdleReleaseTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/models/stand-in.gguf")

    func testTheModelIsReleasedOnceTheIdleTimeHasPassed() async throws {
        let (engine, gate, models) = make()
        try await engine.load(model: url)
        await gate.started(1)
        let held = await engine.holdsModel
        XCTAssertTrue(held)
        await gate.elapse()
        await engine.idleTask?.value
        let released = await engine.holdsModel
        XCTAssertFalse(released)
        XCTAssertEqual(models.freed, 1)
        let asked = await gate.requested
        XCTAssertEqual(asked, [.seconds(20)])
    }

    func testEachUseStartsTheIdleTimeAgain() async throws {
        let (engine, gate, models) = make()
        try await engine.load(model: url)
        await gate.started(1)
        let first = await engine.idleTask
        _ = try await engine.transcribe([0.1])
        await gate.started(2)
        // The release that followed the load has lapsed: the use since keeps the model.
        await gate.elapse(0)
        await first?.value
        let held = await engine.holdsModel
        XCTAssertTrue(held)
        XCTAssertEqual(models.freed, 0)
        await gate.elapse()
        await engine.idleTask?.value
        let released = await engine.holdsModel
        XCTAssertFalse(released)
        XCTAssertEqual(models.freed, 1)
    }

    func testTheNextUseAfterAReleaseReloadsTheSameModel() async throws {
        let (engine, gate, models) = make()
        try await engine.load(model: url)
        await gate.started(1)
        await gate.elapse()
        await engine.idleTask?.value
        let text = try await engine.transcribe([0.1, 0.2])
        XCTAssertEqual(text, "2 samples")
        XCTAssertEqual(models.opened, [url, url])
        let held = await engine.holdsModel
        XCTAssertTrue(held)
    }

    func testUnloadFreesAtOnceAndForgetsTheModel() async throws {
        let (engine, _, models) = make()
        try await engine.load(model: url)
        await engine.unload()
        XCTAssertEqual(models.freed, 1)
        do {
            _ = try await engine.transcribe([0.1])
            XCTFail("transcribed after unload")
        } catch {
            XCTAssertEqual(error, .notLoaded)
        }
    }

    func testLoadingAnotherModelFreesTheFirst() async throws {
        let (engine, _, models) = make()
        try await engine.load(model: url)
        try await engine.load(model: URL(fileURLWithPath: "/models/other.gguf"))
        XCTAssertEqual(models.freed, 1)
        XCTAssertEqual(models.opened.last?.lastPathComponent, "other.gguf")
    }

    func testWarmUpLoadsRunsOnceAndStillReleases() async throws {
        let (engine, gate, models) = make()
        try await engine.warmUp(model: url)
        XCTAssertEqual(models.runs, [16000])
        await gate.started(1)
        await gate.elapse()
        await engine.idleTask?.value
        XCTAssertEqual(models.freed, 1)
    }

    func testTheShippedTimingsReleaseWithinThirtySecondsAndStopWakeUpsFirst() {
        let idle = TranscribeEngine.IdleRelease.standard.after
        XCTAssertLessThanOrEqual(idle, .seconds(30))
        // The keep-alive runs about 1.2 times its setting.
        XCTAssertLessThan(Duration.seconds(TranscribeModel.keepAliveSeconds) * 1.3, idle)
    }

    private func make() -> (TranscribeEngine, Gate, Models) {
        let gate = Gate(), models = Models()
        let release = TranscribeEngine.IdleRelease(after: .seconds(20)) { await gate.sleep($0) }
        let engine = TranscribeEngine(idleRelease: release) { url throws(SpeechEngineError) in StandIn(url: url, models: models) }
        return (engine, gate, models)
    }
}

/// What the stand-in models saw: which were opened, run and freed.
private final class Models: Sendable {
    private let state = Mutex((opened: [URL](), runs: [Int](), freed: 0))
    var opened: [URL] { state.withLock { $0.opened } }
    var runs: [Int] { state.withLock { $0.runs } }
    var freed: Int { state.withLock { $0.freed } }
    func open(_ url: URL) { state.withLock { $0.opened.append(url) } }
    func run(_ count: Int) { state.withLock { $0.runs.append(count) } }
    func free() { state.withLock { $0.freed += 1 } }
}

private final class StandIn: LoadedModel {
    private let models: Models

    init(url: URL, models: Models) {
        self.models = models
        models.open(url)
    }

    deinit { models.free() }

    func run(_ samples: [Float]) throws(SpeechEngineError) -> String {
        models.run(samples.count)
        return "\(samples.count) samples"
    }
}

/// Sleeps that end only when the test lets their time pass.
private actor Gate {
    private(set) var requested: [Duration] = []
    private var sleepers: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        let index = requested.count
        requested.append(duration)
        await withCheckedContinuation { sleeper in
            sleepers[index] = sleeper
            arrivals.forEach { $0.resume() }
            arrivals.removeAll()
        }
    }

    /// Returns once `count` sleeps have begun.
    func started(_ count: Int) async {
        while requested.count < count {
            await withCheckedContinuation { arrivals.append($0) }
        }
    }

    /// Ends one sleep, by the order it began in, or every sleep still running.
    func elapse(_ index: Int? = nil) {
        for (key, sleeper) in sleepers where index == nil || key == index {
            sleeper.resume()
            sleepers[key] = nil
        }
    }
}
