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
