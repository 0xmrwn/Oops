import Foundation

/// How a field draws its text at the caret and what sits around it: what words drawn there need, to read as
/// the field's own text would.
public struct CaretStyle: Equatable, Sendable {
    /// The font of the text the caret continues, when the field tells it.
    public var fontName: String?
    public var fontSize: Double?
    /// That text's colour as sRGB red, green and blue, when the field tells it.
    public var color: SIMD3<Double>?
    /// Text follows the caret on its line: words drawn there would cover it.
    public var followed: Bool
    /// The caret comes straight after a word: words drawn there start after a space, as the written text will.
    public var spaced: Bool

    public init(fontName: String? = nil, fontSize: Double? = nil, color: SIMD3<Double>? = nil, followed: Bool = false, spaced: Bool = false) {
        self.fontName = fontName; self.fontSize = fontSize; self.color = color
        self.followed = followed; self.spaced = spaced
    }
}

public extension CaretStyle {
    /// Whether the page behind the field is dark, as its text's colour says: light text is set on a dark page. Nil
    /// when the field keeps its colour to itself, or when the text is a mid tone that says neither.
    var pageIsDark: Bool? {
        guard let color else { return nil }
        // Relative luminance, from sRGB through its transfer curve.
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
        // Text a page could carry either way (around the 18 % grey that sits between black and white) decides nothing.
        if abs(luminance - 0.18) < 0.06 { return nil }
        return luminance > 0.18
    }
}
