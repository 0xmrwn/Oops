import Foundation
import OopsEngine
import XCTest

/// A process that ran the model and then exits, as the app does when it quits: ggml's Metal devices are static, and
/// their destructor aborts if a buffer of a loaded model is still alive. The exit runs in a child process, the same
/// test bundle under xctest, because the abort would end this one. The model comes from OOPS_TEST_MODEL.
final class EngineExitTests: XCTestCase {
    private static let childKey = "OOPS_ENGINE_EXIT_CHILD"

    func testAProcessThatRanTheModelExitsCleanly() throws {
        guard let model = ProcessInfo.processInfo.environment["OOPS_TEST_MODEL"], !model.isEmpty else {
            throw XCTSkip("set OOPS_TEST_MODEL to a model file to run this")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "OopsEngineTests.EngineExitTests/testChildRunsTheModelThenExits",
                           Bundle(for: Self.self).bundlePath]
        child.environment = ProcessInfo.processInfo.environment.merging([Self.childKey: "1"]) { $1 }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .exit, "the child ended on signal \(child.terminationStatus)")
        XCTAssertEqual(child.terminationStatus, 0)
    }

    /// Only as the child: holds the model, as the app does for a while after each dictation, then exits.
    func testChildRunsTheModelThenExits() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Self.childKey] == "1", let model = environment["OOPS_TEST_MODEL"] else {
            throw XCTSkip("runs only as the child of testAProcessThatRanTheModelExitsCleanly")
        }
        let engine = TranscribeEngine()
        try await engine.warmUp(model: URL(fileURLWithPath: model))
        _ = try await engine.transcribe([Float](repeating: 0, count: 16000))
        // What the app does as it quits, from the main thread with the model still held.
        await MainActor.run { engine.shutDown() }
        exit(0)
    }
}
