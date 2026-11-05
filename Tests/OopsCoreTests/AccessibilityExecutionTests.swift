import ApplicationServices
import XCTest
@testable import OopsCore

final class AccessibilityExecutionTests: XCTestCase {
    func testOwnElementRunsOnMainFromAXWorker() async {
        let onMain: Bool = await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.ax-worker").async {
                let ownApp = AXUIElementCreateApplication(getpid())
                let result = AccessibilityExecution.perform(for: ownApp) { Thread.isMainThread }
                continuation.resume(returning: result)
            }
        }
        XCTAssertTrue(onMain, "Same-process AX selection calls enter AppKit and must run on main")
    }

    func testRemoteElementKeepsAXWorker() async {
        let onMain: Bool = await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.ax-worker").async {
                let otherApp = AXUIElementCreateApplication(1)
                let result = AccessibilityExecution.perform(for: otherApp) { Thread.isMainThread }
                continuation.resume(returning: result)
            }
        }
        XCTAssertFalse(onMain, "Remote AX IPC must not block the app's main thread")
    }

    func testOwnElementAlreadyOnMainDoesNotRedispatch() async {
        let onMain = await MainActor.run {
            AccessibilityExecution.perform(for: AXUIElementCreateApplication(getpid())) { Thread.isMainThread }
        }
        XCTAssertTrue(onMain)
    }
}
