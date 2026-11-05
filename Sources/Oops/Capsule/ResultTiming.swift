import Foundation

/// How long a finished correction stays on screen: the success drop and the flash over the changed
/// words share one setting (Settings → General). The flash ends inside the drop's time, never after.
enum ResultTiming {
    static let key = "ResultSeconds"
    static let choices: [Double] = [1.5, 2, 3, 5]
    static let fallback = 2.0

    static var seconds: Double {
        let saved = UserDefaults.standard.double(forKey: key)
        return choices.contains(saved) ? saved : fallback
    }

    /// The flash's fade, leaving room for its staggered start (0.35 s) and the drop appearing just after it.
    static var flash: Double { max(0.8, seconds - 0.45) }
}
