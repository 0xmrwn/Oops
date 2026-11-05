import AppKit
import MetalKit
import SwiftUI

/// ShaderGradient as a SwiftUI background. Drawn at one pixel per point, as the canvas's
/// `pixelDensity={1}` is, and scaled up to the screen by the window.
struct ShaderGradientView: NSViewRepresentable {
    var gradient = ShaderGradient.hello

    func makeNSView(context: Context) -> GradientMetalView { GradientMetalView(gradient: gradient) }
    func updateNSView(_ view: GradientMetalView, context: Context) { view.gradient = gradient }
}

final class GradientMetalView: MTKView, MTKViewDelegate {
    var gradient: ShaderGradient
    private var renderer: GradientRenderer?
    private var started: CFTimeInterval?

    /// One renderer for the app: its geometry and pipelines take a moment to build.
    @MainActor static let shared = Task.detached { () -> GradientRenderer? in
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? GradientRenderer(device: device)
    }

    init(gradient: ShaderGradient) {
        self.gradient = gradient
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = GradientRenderer.outputFormat
        // The canvas's values go to the screen as they are: no tone mapping, no encoding.
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = false
        preferredFramesPerSecond = 60
        delegate = self
        Task { [weak self] in
            let renderer = await Self.shared.value
            self?.renderer = renderer
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let size = CGSize(width: max(1, bounds.width.rounded()), height: max(1, bounds.height.rounded()))
        if drawableSize != size { drawableSize = size }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer, let drawable = currentDrawable, let buffer = renderer.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        if started == nil { started = now }
        let moving = gradient.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        renderer.encode(gradient, time: moving ? gradient.uTime + Float(now - (started ?? now)) : gradient.uTime, to: drawable.texture, in: buffer)
        buffer.present(drawable)
        buffer.commit()
    }
}
