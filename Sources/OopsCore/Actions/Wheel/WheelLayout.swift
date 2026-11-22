import CoreGraphics
import Foundation

/// The wheel's measurements and its eight compass places. Springs, spacing and timings were tuned by eye against
/// real glass: change them only by looking at the result.
public enum WheelLayout {
    /// The centre's width while it is a field.
    public static let field = 320.0
    public static let drop = 46.0, radius = 74.0, petal = 38.0, merge = 40.0, merge8 = 24.0
    public static let response = 0.19, damping = 0.78, stagger = 0.009, wave = 0.06
    /// The window's canvas and the hub inside it.
    public static let canvas = CGSize(width: 600, height: 470), hub = CGPoint(x: 300, y: 235)
    /// Legibility over a busy page: a soft halo behind each glyph, a blurred lens behind each piece, a bright edge on
    /// light pages.
    public static let halo = 0.30, lens = 0.60, labelSize = 14.0, tracking = 0.25, edge = 0.8
    /// Longest name drawn; longer ones are cut with an ellipsis, so the envelope below holds.
    public static let nameLimit = 160.0
    /// The whole wheel at its largest (eight named petals, highlight, lift), which placement keeps on screen.
    public static let envelope = CGSize(width: 570, height: 260)

    /// Clockwise from up: up 0, up-right 1, right 2, and so on to up-left 7.
    public static func slot(_ place: ActionPlace) -> Int {
        switch place {
        case .up: 0
        case .upRight: 1
        case .right: 2
        case .downRight: 3
        case .down: 4
        case .downLeft: 5
        case .left: 6
        case .upLeft: 7
        }
    }

    /// The direction of a place on the canvas, whose y grows downward.
    public static func unit(_ place: ActionPlace) -> CGPoint {
        let angle = Double(slot(place)) * .pi / 4
        return CGPoint(x: sin(angle), y: -cos(angle))
    }

    /// Cardinals first, then diagonals, each clockwise from up: the order petals leave the centre.
    public static func ordered(_ places: some Sequence<ActionPlace>) -> [ActionPlace] {
        places.sorted { (slot($0) % 2, slot($0)) < (slot($1) % 2, slot($1)) }
    }
}
