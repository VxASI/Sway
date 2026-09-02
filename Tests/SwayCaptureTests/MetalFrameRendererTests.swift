#if os(macOS)
import CoreImage
import Metal
import XCTest
@testable import SwayCapture

final class MetalFrameRendererTests: XCTestCase {
    /// The preview draws CoreImage output into an MTKView drawable. CoreImage
    /// is bottom-left origin and Metal textures are top-left, so this pins
    /// down that a pixel in the image's top-left corner ends up in the
    /// texture's top-left corner - the thing a flipped preview would break.
    func testTopLeftOfImageLandsInTopLeftOfTexture() throws {
        guard let renderer = MetalFrameRenderer() else {
            throw XCTSkip("no Metal device")
        }
        let size = 64
        // Red everywhere, except a green square in the image's top-left (in
        // CoreImage terms: high y).
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: size / 2, width: size / 2, height: size / 2))
        let image = green.composited(over: red)

        let texture = try XCTUnwrap(renderer.makeTexture(from: image, width: size, height: size))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(
            &pixels,
            bytesPerRow: size * 4,
            from: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0
        )
        func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * size + x) * 4
            return (pixels[index], pixels[index + 1], pixels[index + 2])
        }
        // Texture row 0 is the top. BGRA layout.
        let topLeft = pixel(x: 4, y: 4)
        let bottomRight = pixel(x: size - 4, y: size - 4)
        XCTAssertGreaterThan(topLeft.g, 200, "top-left should be green: \(topLeft)")
        XCTAssertLessThan(topLeft.r, 50)
        XCTAssertGreaterThan(bottomRight.r, 200, "bottom-right should be red: \(bottomRight)")
    }
}
#endif
