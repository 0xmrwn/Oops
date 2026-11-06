import AppKit
import MetalKit
import SwiftUI

/// ShaderGradient as a SwiftUI background. Drawn at one pixel per point, as the canvas's
/// `pixelDensity={1}` is, and scaled up to the screen by the window.
struct ShaderGradientView: NSViewRepresentable {
    var gradient = ShaderGradient.hello
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> GradientMetalView {
        GradientMetalView(gradient: gradient, reduceMotion: reduceMotion, visible: visible)
    }

    func updateNSView(_ view: GradientMetalView, context: Context) {
        view.update(gradient: gradient, reduceMotion: reduceMotion, visible: visible)
    }

    static func dismantleNSView(_ view: GradientMetalView, coordinator: ()) { view.stopDrawing() }
}

final class GradientMetalView: MTKView, MTKViewDelegate {
    private(set) var gradient: ShaderGradient
    private var reduceMotion: Bool
    private var visible: Bool
    private var dismantled = false
    private var renderer: GradientRenderer?
    private var started: CFTimeInterval?

    // Views own the renderer. The build task is shared only while its geometry and pipelines are being built.
    @MainActor private weak static var sharedRenderer: GradientRenderer?
    @MainActor private static var rendererBuild: Task<GradientRenderer?, Never>?

    @MainActor private static func acquireRenderer() async -> GradientRenderer? {
        if let sharedRenderer { return sharedRenderer }
        if let rendererBuild { return await rendererBuild.value }

        let build = Task.detached { () -> GradientRenderer? in
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            return try? GradientRenderer(device: device)
        }
        rendererBuild = build
        let renderer = await build.value
        sharedRenderer = renderer
        rendererBuild = nil
        return renderer
    }

    init(gradient: ShaderGradient, reduceMotion: Bool, visible: Bool) {
        self.gradient = gradient
        self.reduceMotion = reduceMotion
        self.visible = visible
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = GradientRenderer.outputFormat
        // The canvas's values go to the screen as they are: no tone mapping, no encoding.
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = false
        preferredFramesPerSecond = 60
        delegate = self
        updateDrawing()
        Task { [weak self] in
            let renderer = await Self.acquireRenderer()
            guard let self, !dismantled else { return }
            self.renderer = renderer
            if self.visible { needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(gradient: ShaderGradient, reduceMotion: Bool, visible: Bool) {
        guard !dismantled, self.gradient != gradient || self.reduceMotion != reduceMotion || self.visible != visible else { return }
        self.gradient = gradient
        self.reduceMotion = reduceMotion
        self.visible = visible
        updateDrawing()
    }

    func stopDrawing() {
        dismantled = true
        visible = false
        updateDrawing()
        delegate = nil
        renderer = nil
    }

    /// A frozen wallpaper still redraws when its inputs or size change, without a timer.
    private func updateDrawing() {
        isPaused = !visible || !gradient.animate || reduceMotion
        enableSetNeedsDisplay = visible && isPaused
        needsDisplay = visible
    }

    override func layout() {
        super.layout()
        let size = CGSize(width: max(1, bounds.width.rounded()), height: max(1, bounds.height.rounded()))
        if drawableSize != size { drawableSize = size; if visible { needsDisplay = true } }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard visible, let renderer, let drawable = currentDrawable, let buffer = renderer.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        if started == nil { started = now }
        let moving = gradient.animate && !reduceMotion
        renderer.encode(gradient, time: moving ? gradient.uTime + Float(now - (started ?? now)) : gradient.uTime, to: drawable.texture, in: buffer)
        buffer.present(drawable)
        buffer.commit()
    }
}
