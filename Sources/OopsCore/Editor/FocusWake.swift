import Foundation

/// Chromium hosts (Teams' Edge WebView) let their accessibility tree go dormant and answer the
/// focused-element query with no value. Reading the app element wakes it; retry briefly before
/// giving up. Synchronous: it runs on the Accessibility worker queue.
public enum FocusWake {
    /// The element and how many retries it took (0 when focus was found without waking), or nil.
    /// Teams can stay dormant past one wake: `rewakeEvery` retries, the app is read again.
    public static func resolve<T>(
        lookup: () -> T?, wake: () -> Void, check: () throws -> Void = {},
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        interval: TimeInterval = 0.1, attempts: Int = 10, rewakeEvery: Int = 8
    ) throws -> (element: T, retries: Int)? {
        if let element = lookup() { return (element, 0) }
        wake()
        for retry in 1...attempts {
            try check()
            pause(interval)
            if let element = lookup() { return (element, retry) }
            if retry.isMultiple(of: rewakeEvery) { wake() }
        }
        return nil
    }
}
