import Foundation

/// The colour of the wheel's words, decided once per opening so no glyph ever changes tone in view.
public struct WheelInk: Equatable, Sendable {
    /// Dark glyphs (a light page) or light ones.
    public var dark: Bool
    /// Increase Contrast or Reduce Transparency: the appearance's own ink, no halo, no lens, no feather.
    public var plain: Bool

    /// The page's tone from the field's text colour when it tells, else the system's. AppKit text in its default
    /// colour reports pure black whatever the appearance (measured in a dark text view), so in dark mode pure black
    /// tells nothing outside a web page, whose colours are the ones it draws.
    public init(page: CaretStyle?, web: Bool = false, systemDark: Bool, increaseContrast: Bool, reduceTransparency: Bool) {
        let told = systemDark && !web && page?.color == SIMD3(0, 0, 0) ? nil : page?.pageIsDark
        dark = !(told ?? systemDark)
        plain = increaseContrast || reduceTransparency
    }
}
