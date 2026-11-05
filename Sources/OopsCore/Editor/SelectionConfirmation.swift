import ApplicationServices
import Foundation

/// Confirm a selection action through the editor's reported range before paste.
public enum SelectionConfirmation {
    public enum Failure: LocalizedError, Equatable {
        case rejected(code: Int32)
        case unconfirmed(expected: NSRange, observed: NSRange?)

        public var errorDescription: String? {
            switch self {
            case .rejected:
                return "The text-selection request failed. Your correction is ready to copy."
            case .unconfirmed:
                return "The editor did not confirm the requested text selection in time. Your correction is ready to copy."
            }
        }

        /// Numeric metadata only: never include the draft or clipboard contents.
        public var diagnostic: String {
            switch self {
            case .rejected(let code): return "selection_write_rejected ax_code=\(code)"
            case .unconfirmed(let expected, let observed):
                let actual = observed.map { "\($0.location):\($0.length)" } ?? "unavailable"
                return "selection_unconfirmed requested=\(expected.location):\(expected.length) observed=\(actual)"
            }
        }
    }

    @discardableResult
    public static func require(
        _ requested: NSRange,
        write: () -> AXError,
        read: () -> NSRange?,
        validate: () throws -> Void,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> Int {
        try validate()
        let deadline = now() + 0.3
        let status = write()
        guard status == .success else { throw Failure.rejected(code: status.rawValue) }
        var observed: NSRange?
        // Chromium can acknowledge the action before its AX cache receives the
        // new selection. Submit once, then poll only while the original draft,
        // focused element, cancellation token and input gate remain valid.
        for attempt in 1...16 {
            try validate()
            guard now() <= deadline else { break }
            observed = read()
            guard now() <= deadline else { break }
            if observed == requested {
                try validate()
                guard now() <= deadline else { break }
                return attempt
            }
            let remaining = deadline - now()
            guard remaining > 0 else { break }
            pause(min(0.025, remaining))
        }
        throw Failure.unconfirmed(expected: requested, observed: observed)
    }
}
