import Metal
import OopsCore
import QuartzCore

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

/// Draws one frame of a simulation into a layer's next drawable: the uniforms of its pose and palette, and
/// the packed dots in a three-slot ring so a frame in flight never reads a slot being rewritten.
@MainActor
final class DotScopeRenderer {
    private let gpu: DotScopeMetalPipeline
    private let dotBuffer: MTLBuffer
    private var ringIndex = 0

    init?() {
        guard let gpu = DotScopeMetalPipeline.shared,
              let buffer = gpu.device.makeBuffer(
                  length: DotScopeTuning.maxDots * MemoryLayout<SIMD2<UInt16>>.stride * 3,
                  options: .storageModeShared
              ) else { return nil }
        self.gpu = gpu
        self.dotBuffer = buffer
    }

    func configure(_ layer: CAMetalLayer) {
        layer.device = gpu.device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.allowsNextDrawableTimeout = false
        layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    func render(_ simulation: DotScopeSimulation, into metalLayer: CAMetalLayer, isDark: Bool, drawPlate: Bool, withTransaction: Bool) {
        if metalLayer.presentsWithTransaction != withTransaction {
            metalLayer.presentsWithTransaction = withTransaction
        }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = gpu.queue.makeCommandBuffer() else {
            return
        }

        let pose = simulation.pose
        let palette = DotScopePalette.palette(
            isDark: isDark,
            pose: pose,
            saturation: simulation.tuning.saturation
        )
        let scale = Float(max(1.0, metalLayer.contentsScale))
        let resX = Float(metalLayer.drawableSize.width)
        let resY = Float(metalLayer.drawableSize.height)
        let curveFlag: Float = simulation.tuning.fitsBounds ? 1.0 : 0.0

        var uniforms = DotScopeMetalUniforms(
            metrics0: SIMD4<Float>(resX, resY, scale, simulation.tuning.spacing),
            metrics1: SIMD4<Float>(pose.width, pose.height, pose.opacity, pose.scale),
            metrics2: SIMD4<Float>(
                pose.softness,
                Float(simulation.columns),
                Float(simulation.rows),
                pose.height * 0.5
            ),
            state: SIMD4<Float>(pose.glow, pose.grid, pose.live, isDark ? 1.0 : 0.0),
            window: SIMD4<Float>(
                pose.leadingInset,
                pose.trailingInset,
                simulation.tuning.windowFade,
                curveFlag
            ),
            base: SIMD4<Float>(palette.base.x, palette.base.y, palette.base.z, drawPlate ? 1.0 : 0.0),
            core: SIMD4<Float>(palette.core.x, palette.core.y, palette.core.z, pose.cool),
            plate: palette.plate,
            rim: palette.rim,
            shadow: palette.shadow
        )

        let slotStride = DotScopeTuning.maxDots * MemoryLayout<SIMD2<UInt16>>.stride
        let slotOffset = ringIndex * slotStride
        ringIndex = (ringIndex + 1) % 3

        let packed = simulation.packedDots
        if !packed.isEmpty {
            let dst = dotBuffer.contents().advanced(by: slotOffset)
            packed.withUnsafeBytes { raw in
                if let baseAddr = raw.baseAddress {
                    memcpy(dst, baseAddr, min(slotStride, raw.count))
                }
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(gpu.scopePipeline)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<DotScopeMetalUniforms>.stride,
                index: 0
            )
            encoder.setFragmentBuffer(dotBuffer, offset: slotOffset, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        if withTransaction {
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            drawable.present()
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
