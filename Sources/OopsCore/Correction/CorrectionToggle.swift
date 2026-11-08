import Foundation

/// What Fix text's shortcut does to the field Oops last corrected (D10). Pressed again while the field
/// holds exactly what the correction left, it restores the original; pressed once more while it holds
/// exactly the original that restore put back, it re-applies the fix without asking the model. Typed
/// since, another field, or later than five minutes: it corrects, as a first press does.
public struct CorrectionToggle: Equatable, Sendable {
    public enum State: Equatable, Sendable { case corrected, restored }
    public enum Press: Equatable, Sendable { case correct, restore, reapply }

    /// As long as an original stays in memory.
    public static let window: TimeInterval = 300

    /// The whole draft before and after the correction.
    public let original: String
    public let applied: String
    public private(set) var state: State
    /// When Oops last put either text in the field.
    public private(set) var date: Date

    public init(original: String, applied: String, state: State = .corrected, date: Date = Date()) {
        self.original = original; self.applied = applied; self.state = state; self.date = date
    }

    /// `text` is the whole draft the field holds now. A space read back as a non-breaking one is the
    /// same draft (Chromium swaps them as it rebuilds its tree); any other difference, whitespace
    /// included, is the person's edit.
    public func press(holding text: String, sameField: Bool, at now: Date = Date()) -> Press {
        guard sameField, isFresh(at: now) else { return .correct }
        switch state {
        case .corrected: return sameDraft(text, applied) ? .restore : .correct
        case .restored: return sameDraft(text, original) ? .reapply : .correct
        }
    }

    /// Whether the drop's button or the menu can still take the correction back.
    public func canRestore(at now: Date = Date()) -> Bool { state == .corrected && isFresh(at: now) }

    /// After a restore or a re-apply landed: the other text is in the field, and the five minutes start again.
    public func toggled(at now: Date = Date()) -> Self {
        Self(original: original, applied: applied, state: state == .corrected ? .restored : .corrected, date: now)
    }

    private func isFresh(at now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < Self.window
    }

    /// Whether a field found where the earlier one was is the app's remount of it rather than another field
    /// beside it: the same left edge and width, a height that differs by at most a line or two (a composer
    /// growing or shrinking with the fix), and the top or the bottom edge where it was.
    public static func sameSlot(_ now: CGRect, _ earlier: CGRect) -> Bool {
        let close = { (a: CGFloat, b: CGFloat, tolerance: CGFloat) in abs(a - b) <= tolerance }
        return close(now.minX, earlier.minX, 2) && close(now.width, earlier.width, 2) && close(now.height, earlier.height, 40)
            && (close(now.minY, earlier.minY, 2) || close(now.maxY, earlier.maxY, 2))
    }
}
