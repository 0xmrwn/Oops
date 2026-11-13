import Foundation

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

// MARK: - Tuning & Stage (`src/dot_scope.rs`, `src/dot_scope/scope.rs`)

package enum DotScopeStage: Equatable, Sendable {
    case idle
    case recording
    case processing
    case done
    case failed
}

/// What a caller asks the scope to show; the simulation's stage is derived from it.
package enum DotScopePhase: Equatable, Sendable {
    case hidden
    case idle
    case recording
    case processing
    case failed
}

package struct DotScopeTuning: Equatable, Sendable {
    static let maxColumns = 192
    static let maxRows = 21
    package static let maxDots = 4096

    package var columns: Int = 43
    package var rows: Int = 9
    package var spacing: Float = 2.6
    package var width: Float = 112.0
    package var idleWidth: Float = 112.0
    package var processingWidth: Float = 76.0
    package var height: Float = 26.0
    package var fitsBounds: Bool = false
    package var leadingInset: Float = 0.0
    package var trailingInset: Float = 0.0
    package var windowFade: Float = 0.0
    package var braidSpeed: Float = 1.0
    package var helixCycles: Float = 1.6
    package var gain: Float = 1.0
    package var response: Float = 6.5
    package var release: Float = 0.15
    package var historySpeed: Float = 150.0
    package var phosphor: Float = 0.60
    package var glow: Float = 1.0
    package var saturation: Float = 1.0
    package var shimmerPass: Float = 0.55
    package var shimmer: Float = 1.0
    package var transition: Float = 0.28
    package var bounce: Float = 0.08
    package var autoLevel: Bool = true
    package var autoRelease: Float = 3.0
    package var noiseFloor: Float = -60.0

    package init() {}

    package static let hud = DotScopeTuning()

    /// Even-margin sizing matching `dictation_indicator::fill_island`.
    package static func sized(
        width targetWidth: Float,
        idleWidth targetIdle: Float = 120,
        processingWidth targetProcessing: Float,
        height: Float = 30.0,
        rows: Int = 9,
        spacing: Float = 2.75,
        gain: Float = 1.18
    ) -> DotScopeTuning {
        var outer = (height - Float(rows - 1) * spacing) * 0.5
        if outer < 3.0, rows > 2 {
            outer += spacing
        }
        let maxCols = min(maxColumns, maxDots / max(rows, 1))
        let cols = max(11, min(maxCols, Int(floor((targetWidth - 2.0 * outer) / spacing)) + 1))
        let snappedWidth = Float(cols - 1) * spacing + 2.0 * outer
        var t = DotScopeTuning()
        t.columns = cols
        t.rows = rows
        t.spacing = spacing
        t.width = snappedWidth
        t.idleWidth = min(snappedWidth, max(height, targetIdle))
        t.processingWidth = min(snappedWidth, max(height, targetProcessing))
        t.height = height
        t.gain = gain
        return t
    }

    /// Full-width bar scope matching OpenCode iOS's `DictationScopeBar`:
    /// spans the entire capsule bar pixel-exact and softly fades around leading/trailing buttons.
    package static func bar(
        leadingInset: Float = 0,
        trailingInset: Float = 0,
        fade: Float = 28.0,
        spacing: Float = 3.5
    ) -> DotScopeTuning {
        var t = DotScopeTuning()
        t.fitsBounds = true
        t.spacing = spacing
        t.width = 340.0
        t.idleWidth = 340.0
        t.processingWidth = 340.0
        t.height = 44.0
        t.columns = 96
        t.rows = 11
        t.leadingInset = max(0, leadingInset)
        t.trailingInset = max(0, trailingInset)
        t.windowFade = fade
        t.helixCycles = 2.1
        t.gain = 1.18
        t.historySpeed = 210.0
        t.transition = 0.28
        t.bounce = 0.0
        return t
    }

    /// Returns a copy whose grid is pixel-snapped to a real Metal drawable (`DotScopeGrid`).
    package func fitted(pixelWidth: Int, pixelHeight: Int, scale rawScale: Float) -> DotScopeTuning {
        guard fitsBounds, pixelWidth > 8, pixelHeight > 8 else { return self }
        let scale = max(1.0, rawScale)
        let pxPitch = max(3.0, (spacing * scale).rounded())
        let pitch = pxPitch / scale
        let w = Float(pixelWidth) / scale
        let h = Float(pixelHeight) / scale

        let rawRows = min(13, min(Self.maxRows, max(5, Int(floor(Float(pixelHeight) / pxPitch)) - 1)))
        let oddRows = rawRows.isMultiple(of: 2) ? max(5, rawRows - 1) : rawRows
        let maxCols = min(Self.maxColumns, Self.maxDots / max(oddRows, 1))
        let cols = max(11, min(maxCols, Int(floor(Float(pixelWidth) / pxPitch)) - 1))

        var copy = self
        copy.spacing = pitch
        copy.width = w
        copy.idleWidth = w
        copy.processingWidth = w
        copy.height = h
        copy.columns = cols
        copy.rows = oddRows
        return copy
    }

    package static let keyboard = DotScopeTuning.sized(width: 152, idleWidth: 122, processingWidth: 96, height: 30, rows: 9, spacing: 2.75)
    package static let handoff = DotScopeTuning.bar(leadingInset: 0, trailingInset: 0, fade: 30.0, spacing: 3.5)
}

package struct DotScopePose: Equatable, Sendable {
    package var width: Float
    package var height: Float
    package var activeSpan: Float
    package var activeCenter: Float
    package var leadingInset: Float
    package var trailingInset: Float
    package var opacity: Float
    package var scale: Float
    package var softness: Float
    package var cool: Float
    package var fail: Float
    package var glow: Float
    package var grid: Float
    package var live: Float
}

package struct DotScopePalette: Equatable, Sendable {
    package var base: SIMD3<Float>
    package var core: SIMD3<Float>
    package var plate: SIMD4<Float>
    package var rim: SIMD4<Float>
    package var shadow: SIMD4<Float>

    package static func dark(pose: DotScopePose, saturation: Float = 1.0) -> DotScopePalette {
        palette(isDark: true, pose: pose, saturation: saturation)
    }

    package static func light(pose: DotScopePose, saturation: Float = 1.0) -> DotScopePalette {
        palette(isDark: false, pose: pose, saturation: saturation)
    }

    /// Matches OpenCode iOS `pearlPalette(dark:)` (`DotScopeView.swift:363-372`).
    package static func palette(isDark: Bool, pose: DotScopePose, saturation: Float = 1.0) -> DotScopePalette {
        let you = isDark
            ? SIMD3<Float>(0.86, 0.83, 0.77)
            : SIMD3<Float>(0.62, 0.53, 0.40)
        let youCore = isDark
            ? SIMD3<Float>(0.98, 0.96, 0.92)
            : SIMD3<Float>(0.47, 0.38, 0.26)
        let agent = isDark
            ? SIMD3<Float>(0.70, 0.75, 0.84)
            : SIMD3<Float>(0.40, 0.47, 0.58)
        let agentCore = isDark
            ? SIMD3<Float>(0.92, 0.95, 1.00)
            : SIMD3<Float>(0.24, 0.31, 0.43)
        let coral = isDark
            ? SIMD3<Float>(1.00, 0.38, 0.31)
            : SIMD3<Float>(0.82, 0.24, 0.20)
        let coralCore = isDark
            ? SIMD3<Float>(1.00, 0.66, 0.60)
            : SIMD3<Float>(0.64, 0.14, 0.12)

        func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            a + (b - a) * t
        }

        func sat(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
            let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let out = SIMD3<Float>(luma, luma, luma) + (c - SIMD3<Float>(luma, luma, luma)) * amount
            return SIMD3<Float>(
                min(1.0, max(0.0, out.x)),
                min(1.0, max(0.0, out.y)),
                min(1.0, max(0.0, out.z))
            )
        }

        let base = mix3(mix3(you, agent, pose.cool), coral, pose.fail)
        let core = mix3(mix3(youCore, agentCore, pose.cool), coralCore, pose.fail)

        return DotScopePalette(
            base: sat(base, saturation),
            core: sat(core, saturation),
            plate: isDark
                ? SIMD4<Float>(17.0 / 255.0, 18.0 / 255.0, 22.0 / 255.0, 0.92)
                : SIMD4<Float>(0.94, 0.95, 0.97, 0.92),
            rim: isDark
                ? SIMD4<Float>(1.0, 1.0, 1.0, 0.04)
                : SIMD4<Float>(0.0, 0.0, 0.0, 0.04),
            shadow: SIMD4<Float>(0.0, 0.0, 0.0, isDark ? 0.22 : 0.10)
        )
    }
}
