import Foundation
import Metal
import simd

/// Draws a ShaderGradient frame as the library does with `grain="off"`: the sphere straight to the
/// canvas, which WebGL multisamples 4× by default. The shader is compiled at run time from the bundled
/// `Shaders/ShaderGradient.metal`.
final class GradientRenderer: @unchecked Sendable {
    struct Uniforms {
        var modelView, projection, view: simd_float4x4
        var color1, color2, color3: SIMD4<Float>
        var time, speed, density, strength, frequency, amplitude, roughness, metalness: Float
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let sphere: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let vertices: MTLBuffer
    private let indices: MTLBuffer
    private let indexCount: Int
    private let environment: MTLTexture
    private var targets: (color: MTLTexture, depth: MTLTexture)?

    static let outputFormat = MTLPixelFormat.bgra8Unorm
    private static let samples = 4

    /// Shader compilation and mesh generation run off the main thread.
    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw GradientError.metal }
        self.queue = queue
        guard let source = Bundle.main.url(forResource: "ShaderGradient", withExtension: "metal", subdirectory: "Shaders") else { throw GradientError.missing("ShaderGradient") }
        let scene = try device.makeLibrary(source: String(contentsOf: source, encoding: .utf8), options: nil)

        let sphereDescriptor = MTLRenderPipelineDescriptor()
        sphereDescriptor.vertexFunction = scene.makeFunction(name: "sphereVertex")
        sphereDescriptor.fragmentFunction = scene.makeFunction(name: "sphereFragment")
        sphereDescriptor.colorAttachments[0].pixelFormat = Self.outputFormat
        sphereDescriptor.depthAttachmentPixelFormat = .depth32Float
        sphereDescriptor.rasterSampleCount = Self.samples
        sphere = try device.makeRenderPipelineState(descriptor: sphereDescriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual // three's LessEqualDepth
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw GradientError.metal }
        self.depth = depth

        let geometry = GradientScene.sphere()
        guard let vertices = device.makeBuffer(bytes: geometry.vertices, length: geometry.vertices.count * MemoryLayout<Float>.stride),
              let indices = device.makeBuffer(bytes: geometry.indices, length: geometry.indices.count * MemoryLayout<UInt16>.stride)
        else { throw GradientError.metal }
        self.vertices = vertices
        self.indices = indices
        indexCount = geometry.indices.count

        // three's PMREM of the "city" HDR, the rows this material reads (see ShaderGradient.metal).
        guard let url = Bundle.main.url(forResource: "city-pmrem", withExtension: "bin", subdirectory: "Gradient") else { throw GradientError.missing("city-pmrem") }
        let data = try Data(contentsOf: url)
        let rows = 32, width = data.count / (rows * 8)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: rows, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GradientError.metal }
        data.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, rows), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        environment = texture
    }

    /// Encodes one frame of `gradient` at `time` seconds into `output`, sized in pixels like the canvas.
    func encode(_ gradient: ShaderGradient, time: Float, to output: MTLTexture, in buffer: MTLCommandBuffer) {
        let width = output.width, height = output.height
        guard let (color, depthTexture) = targets(width: width, height: height) else { return }

        let model = GradientScene.model(gradient), view = GradientScene.view(gradient)
        let projection = GradientScene.projection(gradient, aspect: Double(width) / Double(height))
        var uniforms = Uniforms(modelView: Self.single(view * model), projection: Self.single(projection), view: Self.single(view),
                                color1: SIMD4(gradient.color1, 1), color2: SIMD4(gradient.color2, 1), color3: SIMD4(gradient.color3, 1),
                                time: time, speed: gradient.uSpeed, density: gradient.uDensity, strength: gradient.uStrength,
                                frequency: gradient.uFrequency, amplitude: gradient.uAmplitude,
                                roughness: 1 - gradient.reflection, metalness: 0.2)

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = color
        scenePass.colorAttachments[0].resolveTexture = output
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        scenePass.colorAttachments[0].storeAction = .multisampleResolve
        scenePass.depthAttachment.texture = depthTexture
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.clearDepth = 1
        scenePass.depthAttachment.storeAction = .dontCare
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.setRenderPipelineState(sphere)
            encoder.setDepthStencilState(depth)
            encoder.setCullMode(.none) // DoubleSide
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(environment, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: indices, indexBufferOffset: 0)
            encoder.endEncoding()
        }
    }

    func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// Matrices are worked out in double precision, as JavaScript does, and uploaded as floats, as three does.
    private static func single(_ m: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }

    /// The multisampled colour and depth targets, resolved and discarded every frame: memoryless on
    /// Apple GPUs, private on the Intel Macs' AMD and Intel GPUs, which have no memoryless storage.
    /// Nil when Metal can't allocate them, and the frame is skipped.
    private func targets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let targets, targets.color.width == width, targets.color.height == height { return targets }
        let storage: MTLStorageMode = device.supportsFamily(.apple1) ? .memoryless : .private
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.textureType = .type2DMultisample
            descriptor.sampleCount = Self.samples
            descriptor.usage = .renderTarget
            descriptor.storageMode = storage
            return device.makeTexture(descriptor: descriptor)
        }
        guard let color = texture(Self.outputFormat), let depth = texture(.depth32Float) else { return nil }
        targets = (color, depth)
        return (color, depth)
    }
}

enum GradientError: Error { case metal, missing(String) }
