import AppKit
import Metal
@testable import Oops
import OopsCore
import Testing

// `testHostViewLoudnessUpdatesNeverResetSimulationClock` is ported from Hex's `ios/HEXMobileTests/DotScopeTests.swift`
// (MIT, Copyright (c) 2026 Christopher Langton). See THIRD_PARTY_NOTICES.md.

@MainActor struct DotScopeHostTests {
    @Test func `host view loudness updates never reset simulation clock`() {
        var liveDB: Float = -34.0
        let host = DotScopeHostView(tuning: .bar(leadingInset: 45, trailingInset: 77))
        host.frame = CGRect(x: 0, y: 0, width: 373, height: 44)
        host.useDemoVoice = true
        host.loudnessProvider = { liveDB }
        host.phase = .recording

        host.stepAndRender(timestamp: 10.0, targetTimestamp: 10.0 + 1.0 / 60.0)
        host.stepAndRender(timestamp: 10.0 + 1.0 / 60.0, targetTimestamp: 10.0 + 2.0 / 60.0)
        let tBefore = host.debugElapsedTime
        #expect(tBefore > 0.01)

        // Updating live loudness 10 times during `.recording` must never reset `elapsedTime`.
        for step in 1...10 {
            liveDB = -34.0 + Float(step) * 0.8
            host.phase = .recording
            let ts = 10.0 + Double(step + 1) / 60.0
            host.stepAndRender(timestamp: ts, targetTimestamp: ts + 1.0 / 60.0)
        }
        #expect(host.debugElapsedTime > tBefore + 0.14)
    }

    @Test func `the bundled dot scope shader compiles and builds its pipeline`() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return } // no GPU: nothing to compile on
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Shaders/DotScopeShader.metal")
        let library = try DotScopeMetalPipeline.library(on: device, source: source)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "dot_scope_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "dot_scope_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
