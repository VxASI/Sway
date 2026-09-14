#if os(macOS)
import AppKit
import CoreImage
import CoreGraphics
import XCTest
@testable import SwayCapture
@testable import SwayCore

/// A recorded pointer PNG is stored top row first (an arrow's tip is near the
/// top-left of the image). Drawn back in, the tip must sit on the hotspot and
/// the body must hang down-right - in the CPU path the exporter uses and in
/// the Metal path the preview uses.
final class RecordedShapeOrientationTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 200)

    /// A 17x23 "arrow": opaque in a triangle whose tip is the top-left pixel.
    private func arrowPNGImage() throws -> CGImage {
        let w = 17, h = 23
        let context = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        // CGContext origin is bottom-left; the tip at top-left is (0, h).
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 6))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fillPath()
        // Round-trip through PNG, exactly like the recorder stores it.
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func renderer(_ image: CGImage) -> CursorRenderer {
        var style = CursorStyle.standard
        style.shape = .recorded
        style.size = 1
        style.smoothing = 0
        style.clickRings = false
        let shapes = CursorShapeTrack(
            shapes: [CursorShape(id: "a", fileName: "a.png", width: 17, height: 23, hotspotX: 0, hotspotY: 0)],
            changes: [CursorShapeChange(time: 0, shapeID: "a")]
        )
        return CursorRenderer(
            style: style,
            track: CursorTrack(events: [CursorEvent(time: 0, x: 0.5, y: 0.5, type: .move)]),
            shapes: shapes, shapeImages: ["a": image], scale: 1
        )
    }

    /// Counts opaque pixels in the rows above and below the hotspot (top-left
    /// coordinates, y down) from a BGRA readback.
    private func split(_ bgra: [UInt8], width: Int, hotspotY: Int) -> (above: Int, below: Int) {
        var above = 0, below = 0
        for y in 0..<200 { for x in 0..<200 where bgra[(y * width + x) * 4 + 3] > 128 {
            if y < hotspotY { above += 1 } else { below += 1 }
        } }
        return (above, below)
    }

    func testCPUPathDrawsTheBodyBelowTheTip() throws {
        let image = renderer(try arrowPNGImage())
            .draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 0)
        var bytes = [UInt8](repeating: 0, count: 200 * 200 * 4)
        // `render(toBitmap:)` writes rows top-down, like a CGImage.
        CIContext().render(image, toBitmap: &bytes, rowBytes: 800, bounds: extent, format: .BGRA8, colorSpace: nil)
        let counts = split(bytes, width: 200, hotspotY: 100)
        XCTAssertEqual(counts.above, 0, "nothing above the tip")
        XCTAssertGreaterThan(counts.below, 100)
    }

    func testMetalPathDrawsTheBodyBelowTheTip() throws {
        guard let metal = MetalFrameRenderer() else { throw XCTSkip("no Metal device") }
        let image = renderer(try arrowPNGImage())
            .draw(on: CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0)).cropped(to: extent),
                  fullExtent: extent, time: 0)
        let texture = try XCTUnwrap(metal.makeTexture(from: image, width: 200, height: 200))
        var bytes = [UInt8](repeating: 0, count: 200 * 200 * 4)
        texture.getBytes(&bytes, bytesPerRow: 800, from: MTLRegionMake2D(0, 0, 200, 200), mipmapLevel: 0)
        let counts = split(bytes, width: 200, hotspotY: 100)
        XCTAssertEqual(counts.above, 0, "nothing above the tip")
        XCTAssertGreaterThan(counts.below, 100)
    }
}
#endif
