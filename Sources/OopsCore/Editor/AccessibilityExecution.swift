import ApplicationServices
import Foundation

/// Same-process AX calls invoke AppKit directly, rather than dispatching IPC to
/// another app's main thread. Keep that distinction at the AX call boundary.
public enum AccessibilityExecution {
    public static func perform<T>(for element: AXUIElement, _ operation: () -> T) -> T {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid(), !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: operation)
        }
        return operation()
    }
}
