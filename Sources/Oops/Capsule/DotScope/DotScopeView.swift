import OopsCore
import SwiftUI

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

/// The dot scope: two braided traces of dots that follow the voice while `phase` is `.recording`, turn to a
/// cool shimmer while `.processing`, and fade in and out with `.idle` and `.hidden`. `loudness` is in
/// decibels, set per frame while recording (about -60 silent to -20 loud; at or below -80 counts as silence).
/// The scope drives its own display link and pauses it when settled or out of sight, so a caller only sets
/// these four values. The background is transparent: the dots sit on whatever is behind the view.
struct DotScopeView: NSViewRepresentable {
    var phase: DotScopePhase
    var loudness: Float = -62.0
    var isDark: Bool = true
    var reduceMotion: Bool = false
    var tuning: DotScopeTuning = .hud
    /// Off: the scope sits directly on the capsule's glass. On draws the original's pill, rim and shadow.
    var drawPlate: Bool = false

    func makeNSView(context: Context) -> DotScopeHostView {
        let view = DotScopeHostView(tuning: tuning)
        view.reduceMotion = reduceMotion
        view.isDark = isDark
        view.drawPlate = drawPlate
        view.loudnessProvider = { [loudness] in loudness }
        view.phase = phase
        return view
    }

    func updateNSView(_ nsView: DotScopeHostView, context: Context) {
        nsView.reduceMotion = reduceMotion
        nsView.isDark = isDark
        nsView.loudnessProvider = { [loudness] in loudness }
        nsView.updateTuning(tuning)
        nsView.drawPlate = drawPlate
        nsView.phase = phase
        nsView.scheduleVisibilityRefresh()
    }
}
