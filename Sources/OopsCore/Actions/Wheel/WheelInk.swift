import Foundation

/// The colour of the wheel's words, decided once per opening so no glyph ever changes tone in view.
public struct WheelInk: Equatable, Sendable {
    /// Dark glyphs (a light page) or light ones.
    public var dark: Bool
    /// Increase Contrast or Reduce Transparency: the appearance's own ink, no halo, no lens, no feather.
    public var plain: Bool

    /// The page's tone from the field's text colour when it tells, else the system's. AppKit text in its default
    /// colour reports pure black or pure white by an appearance other than its window's (measured in light and dark
    /// text views), so outside a web page, whose colours are the ones it draws, those two tell nothing.
    public init(page: CaretStyle?, web: Bool = false, systemDark: Bool, increaseContrast: Bool, reduceTransparency: Bool) {
        let told = !web && page?.color.map(Self.isDefault) == true ? nil : page?.pageIsDark
        dark = !(told ?? systemDark)
        plain = increaseContrast || reduceTransparency
    }

    /// Pure black or pure white, as AppKit's default text colour reads.
    private static func isDefault(_ color: SIMD3<Double>) -> Bool {
        let channels = [color.x, color.y, color.z]
        return channels.allSatisfy { $0 < 0.001 } || channels.allSatisfy { $0 > 0.999 }
    }
}
