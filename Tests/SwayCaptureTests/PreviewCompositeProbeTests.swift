#if os(macOS)
import CoreImage
import CoreVideo
import Metal
import XCTest
@testable import SwayCapture
@testable import SwayCore

/// Renders what the editor preview renders - a video frame, the drawn cursor
/// and the canvas card - through the Metal path at preview (downscaled) size,
/// and checks every layer lands the same way up.
final class PreviewCompositeProbeTests: XCTestCase {
    func testCursorAndCardAreUprightInTheMetalPreview() throws {
        guard let renderer = MetalFrameRenderer() else { throw XCTSkip("no Metal device") }

        // 400x300 source: dark, with a bright band across the bottom 20 rows.
        let w = 400, h = 300
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<h { for x in 0..<w {
            let p = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
            let v: UInt8 = y >= h - 20 ? 255 : 30
            p[0] = v; p[1] = v; p[2] = v; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        // Cursor near the top-left of the frame (normalized 0.1, 0.1).
        var style = CursorStyle.standard
        style.shape = .arrow
        style.clickRings = false
        style.smoothing = 0
        style.size = 3
        let cursor = CursorRenderer(
            style: style,
            track: CursorTrack(events: [CursorEvent(time: 0, x: 0.1, y: 0.1, type: .move)]),
            scale: 1
        )

        // Preview-like output: half size, canvas on with a dark background.
        let output = CGSize(width: 200, height: 150)
        let canvas = CanvasStyle(isEnabled: true, padding: 0.1, cornerRadius: 0, shadow: 0, background: .graphite)
        let image = CameraFrameRenderer.render(
            source: CIImage(cvPixelBuffer: pixelBuffer),
            camera: CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, zoom: 1),
            time: 0, outputSize: output, cursor: cursor, canvas: canvas
        )
        let texture = try XCTUnwrap(renderer.makeTexture(from: image, width: 200, height: 150))
        var px = [UInt8](repeating: 0, count: 200 * 150 * 4)
        texture.getBytes(&px, bytesPerRow: 200 * 4, from: MTLRegionMake2D(0, 0, 200, 150), mipmapLevel: 0)
        func lum(_ x: Int, _ y: Int) -> Int { Int(px[(y * 200 + x) * 4 + 1]) }

        // Padding is 15px. The bright source band (bottom 20 source rows =
        // bottom ~10 output rows of the card) should appear just above the
        // bottom padding, i.e. around y = 131, and NOT near the top.
        XCTAssertGreaterThan(lum(100, 131), 150, "bright band should be at the bottom of the card")
        XCTAssertLessThan(lum(100, 20), 80, "top of the card should be dark")
        // Canvas padding below the card is graphite (dark), not the band.
        XCTAssertLessThan(lum(100, 145), 80, "bottom padding should be canvas")

        // The white cursor arrow: hotspot at (0.1, 0.1) of the card => card
        // x 15+0.1*170=32, y 15+0.1*120=27; the arrow body extends DOWN-RIGHT
        // from the tip. Something bright must exist below-right of the tip,
        // and nothing above-left of it (which would mean an inverted arrow).
        var belowRight = 0, aboveLeft = 0
        for dy in 6...20 { for dx in 2...12 {
            if lum(32 + dx, 27 + dy) > 200 { belowRight += 1 }
            if 27 - dy >= 15, lum(32 + dx, 27 - dy) > 200 { aboveLeft += 1 }
        } }
        XCTAssertGreaterThan(belowRight, 10, "arrow body should extend downward from the tip")
        XCTAssertEqual(aboveLeft, 0, "nothing should be drawn above the tip (inverted arrow)")
    }
}
#endif
