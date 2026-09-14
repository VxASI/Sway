#if os(macOS)
import CoreImage
import CoreVideo
import Metal
import XCTest
@testable import SwayCapture

/// Pixel-buffer sources (video frames) and CGImage sources (cursor, canvas
/// mask, baked gradient) must land the same way up when rendered into a Metal
/// texture, or the cursor draws upside down over an upright frame.
final class MetalOrientationProbeTests: XCTestCase {
    private let size = 64

    private func topLeftIsGreen(_ renderer: MetalFrameRenderer, _ image: CIImage) throws -> (topLeft: Bool, bottomLeft: Bool) {
        let texture = try XCTUnwrap(renderer.makeTexture(from: image, width: size, height: size))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        func green(x: Int, y: Int) -> Bool { pixels[(y * size + x) * 4 + 1] > 200 && pixels[(y * size + x) * 4 + 2] < 60 }
        return (green(x: 4, y: 4), green(x: 4, y: size - 4))
    }

    /// Red frame with a green top-left quadrant, as a CGImage-backed CIImage.
    private func cgImageSource() throws -> CIImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        // CGContext is bottom-left origin: top-left quadrant is high y.
        context.fill(CGRect(x: 0, y: size / 2, width: size / 2, height: size / 2))
        return CIImage(cgImage: try XCTUnwrap(context.makeImage()))
    }

    /// The same picture as a BGRA pixel buffer (row 0 = top, like a decoded
    /// video frame).
    private func pixelBufferSource() throws -> CIImage {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<size {
            for x in 0..<size {
                let p = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                let isGreen = y < size / 2 && x < size / 2
                p[0] = 0; p[1] = isGreen ? 255 : 0; p[2] = isGreen ? 0 : 255; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return CIImage(cvPixelBuffer: pixelBuffer)
    }

    func testBothSourceKindsLandTheSameWayUp() throws {
        guard let renderer = MetalFrameRenderer() else { throw XCTSkip("no Metal device") }
        let cg = try topLeftIsGreen(renderer, cgImageSource())
        let pb = try topLeftIsGreen(renderer, pixelBufferSource())
        XCTAssertTrue(cg.topLeft, "CGImage-backed image should be upright, got \(cg)")
        XCTAssertTrue(pb.topLeft, "pixel-buffer-backed image should be upright, got \(pb)")
    }
}
#endif
