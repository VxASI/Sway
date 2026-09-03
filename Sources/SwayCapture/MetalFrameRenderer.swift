#if os(macOS)
import CoreImage
import Metal
import QuartzCore

/// Renders CoreImage output straight into Metal textures (an `MTKView`'s
/// drawable in the editor). Owns the device, queue and a Metal-backed
/// `CIContext` so the preview never touches the CPU per frame.
public final class MetalFrameRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .name: "ai.sway.preview"
        ])
    }

    /// Draws `image` (whose extent starts at the origin) to fill `texture`,
    /// oriented so that CoreImage's bottom-left origin lands correctly in the
    /// texture's top-left-origin space.
    public func render(_ image: CIImage, to texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        // CIContext writes image row 0 (bottom) into texture row 0 (top), so
        // flip vertically about the texture's midline.
        let flipped = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(texture.height)))
        context.render(
            flipped,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: colorSpace
        )
    }

    /// Convenience for callers that just want the pixels: renders into a new
    /// texture and waits.
    public func makeTexture(from image: CIImage, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        render(image, to: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }
}
#endif
