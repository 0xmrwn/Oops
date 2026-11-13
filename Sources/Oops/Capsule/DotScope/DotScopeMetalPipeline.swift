import Foundation
import Metal

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

/// The uniforms of `dot_scope_fragment`, laid out as the shader's `DotScopeUniforms` (160 bytes).
struct DotScopeMetalUniforms {
    var metrics0: SIMD4<Float>
    var metrics1: SIMD4<Float>
    var metrics2: SIMD4<Float>
    var state: SIMD4<Float>
    var window: SIMD4<Float>
    var base: SIMD4<Float>
    var core: SIMD4<Float>
    var plate: SIMD4<Float>
    var rim: SIMD4<Float>
    var shadow: SIMD4<Float>
}

/// The device, queue and pipeline every scope shares. The shader is compiled at run time from the bundled
/// `Shaders/DotScopeShader.metal`, as `GradientRenderer` does for the gradient; nil when Metal or the
/// source is unavailable, and the scope then draws nothing.
@MainActor
final class DotScopeMetalPipeline {
    static let shared: DotScopeMetalPipeline? = DotScopeMetalPipeline()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let scopePipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? Self.library(on: device),
              let vertex = library.makeFunction(name: "dot_scope_vertex"),
              let scopeFragment = library.makeFunction(name: "dot_scope_fragment") else {
            return nil
        }

        let scopeDesc = MTLRenderPipelineDescriptor()
        scopeDesc.label = "Hex DotScope"
        scopeDesc.vertexFunction = vertex
        scopeDesc.fragmentFunction = scopeFragment
        scopeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let scopePipeline = try? device.makeRenderPipelineState(descriptor: scopeDesc) else {
            return nil
        }

        self.device = device
        self.queue = queue
        self.scopePipeline = scopePipeline
    }

    /// Compiles the bundled source; `source` is overridable so a test can compile the file from the checkout.
    static func library(on device: MTLDevice, source: URL? = nil) throws -> MTLLibrary {
        guard let url = source ?? Bundle.main.url(forResource: "DotScopeShader", withExtension: "metal", subdirectory: "Shaders")
        else { throw GradientError.missing("DotScopeShader") }
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }
}
