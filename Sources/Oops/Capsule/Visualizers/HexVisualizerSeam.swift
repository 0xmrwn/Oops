import SwiftUI

/// The Hex dot scope's place in `DictationVisualizerView`. Stand-in until the scope lands: a still grid of
/// dots whose opacity follows the level. Replace the body with
/// `DotScopeView(phase: phase, loudness: loudness, isDark: isDark, reduceMotion: reduceMotion)`.
@ViewBuilder func hexVisualizer(phase: DictationDropState, loudness: Float, isDark: Bool, reduceMotion: Bool) -> some View {
    let ink = VoiceInk(isDark: isDark).ink
    Canvas { context, size in
        let columns = 11, rows = 5, step = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
        for column in 0..<columns {
            for row in 0..<rows {
                let rect = CGRect(x: (CGFloat(column) + 0.5) * size.width / CGFloat(columns) - 1, y: (CGFloat(row) + 0.5) * step - 1, width: 2, height: 2)
                context.fill(Circle().path(in: rect), with: .color(ink.opacity(0.3 + 0.7 * Double(loudness))))
            }
        }
    }
}
