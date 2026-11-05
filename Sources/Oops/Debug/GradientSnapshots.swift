#if DEBUG
import AppKit
import Metal

/// Debug builds only: `-GradientSnapshots <dir>` renders Hello's ShaderGradient offscreen at 1080 × 675,
/// at the times of the grain-off reference frames rendered by the library itself,
/// and exits, so the port can be compared pixel for pixel without a window.
@MainActor enum GradientSnapshots {
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for time: Float in [0, 2.5, 7] {
            guard let bitmap = frame(time: time) else { return print("No renderer") }
            let name = "frame-\(time == 2.5 ? "2.5" : String(Int(time)))-nograin.png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
    }

    /// One frame of `ShaderGradient.hello`; also the wallpaper behind `ShortcutSnapshots`.
    static func frame(time: Float, width: Int = 1080, height: Int = 675) -> NSBitmapImageRep? {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? GradientRenderer(device: device) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GradientRenderer.outputFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor), let buffer = renderer.makeCommandBuffer() else { return nil }
        renderer.encode(ShaderGradient.hello, time: time, to: output, in: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        // BGRA to RGBA.
        for index in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(index, index + 2) }
        bitmap.bitmapData!.update(from: bytes, count: bytes.count)
        return bitmap
    }
}
#endif
