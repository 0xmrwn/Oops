import Foundation

/// The colour of the wheel's words, decided once per opening so no glyph ever changes tone in view.
public struct WheelInk: Equatable, Sendable {
    /// Dark glyphs (a light page) or light ones.
    public var dark: Bool
    /// Increase Contrast or Reduce Transparency: the appearance's own ink, no halo, no lens, no feather.
    public var plain: Bool

    /// The page's tone from the field's text colour when it tells, else the system's.
    public init(page: CaretStyle?, systemDark: Bool, increaseContrast: Bool, reduceTransparency: Bool) {
        dark = !(page?.pageIsDark ?? systemDark)
        plain = increaseContrast || reduceTransparency
    }
}
