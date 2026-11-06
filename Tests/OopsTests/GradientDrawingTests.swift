import AppKit
@testable import Oops
import Testing

@MainActor struct GradientDrawingTests {
    @Test func `Reduce Motion uses invalidation instead of continuous drawing`() {
        let view = GradientMetalView(gradient: .hello, reduceMotion: true, visible: true)
        #expect(view.isPaused)
        #expect(view.enableSetNeedsDisplay)
        view.update(gradient: .hello, reduceMotion: true, visible: true)
        #expect(view.isPaused)

        var gradient = ShaderGradient.hello
        gradient.uTime = 2.5
        view.update(gradient: gradient, reduceMotion: true, visible: true)
        #expect(view.isPaused)
        #expect(view.enableSetNeedsDisplay)
        #expect(view.gradient == gradient)
    }

    @Test func `motion changes resume the original drawing cadence`() {
        let view = GradientMetalView(gradient: .hello, reduceMotion: false, visible: true)
        #expect(!view.isPaused)
        #expect(!view.enableSetNeedsDisplay)
        #expect(view.preferredFramesPerSecond == 60)

        view.update(gradient: .hello, reduceMotion: true, visible: true)
        #expect(view.isPaused)
        view.update(gradient: .hello, reduceMotion: false, visible: true)
        #expect(!view.isPaused)
        #expect(!view.enableSetNeedsDisplay)

        var gradient = ShaderGradient.hello
        gradient.animate = false
        view.update(gradient: gradient, reduceMotion: false, visible: true)
        #expect(view.isPaused)
        #expect(view.enableSetNeedsDisplay)
    }

    @Test func `a frozen gradient keeps a drawable at its new size`() {
        let view = GradientMetalView(gradient: .hello, reduceMotion: true, visible: true)
        view.frame = NSRect(x: 0, y: 0, width: 80, height: 50)
        view.layout()
        #expect(view.drawableSize == CGSize(width: 80, height: 50))
        #expect(view.enableSetNeedsDisplay)
        #expect(view.isPaused)
    }

    @Test func `hiding stops both drawing modes and showing restores the current preference`() {
        let view = GradientMetalView(gradient: .hello, reduceMotion: false, visible: false)
        #expect(view.isPaused)
        #expect(!view.enableSetNeedsDisplay)

        view.update(gradient: .hello, reduceMotion: false, visible: true)
        #expect(!view.isPaused)
        view.update(gradient: .hello, reduceMotion: false, visible: false)
        #expect(view.isPaused)
        #expect(!view.enableSetNeedsDisplay)

        view.update(gradient: .hello, reduceMotion: true, visible: false)
        #expect(!view.enableSetNeedsDisplay)
        view.update(gradient: .hello, reduceMotion: true, visible: true)
        #expect(view.isPaused)
        #expect(view.enableSetNeedsDisplay)
    }

    @Test func `dismantling detaches the delegate and a late update cannot restart drawing`() {
        let view = GradientMetalView(gradient: .hello, reduceMotion: false, visible: true)
        #expect(view.delegate === view)
        ShaderGradientView.dismantleNSView(view, coordinator: ())
        view.update(gradient: .hello, reduceMotion: false, visible: true)
        #expect(view.delegate == nil)
        #expect(view.isPaused)
        #expect(!view.enableSetNeedsDisplay)
    }
}
