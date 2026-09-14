#if os(macOS)
import CoreImage
import XCTest
@testable import SwayCapture
@testable import SwayCore

final class CanvasRendererTests: XCTestCase {
    private let context = CIContext()

    private func pixel(_ image: CIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (bytes[2], bytes[1], bytes[0])
    }

    func testCanvasKeepsOutputSizeAndInsetsTheRecording() {
        // A pure white "recording".
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let output = CGSize(width: 400, height: 300)
        let style = CanvasStyle(isEnabled: true, padding: 0.1, cornerRadius: 0.05, shadow: 0, background: .graphite)
        let camera = CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, zoom: 1)

        let image = CameraFrameRenderer.render(
            source: source, camera: camera, time: 0, outputSize: output, cursor: nil, canvas: style
        )

        XCTAssertEqual(image.extent.size, output)
        // Center is the recording (white); the very corner is canvas (dark).
        let center = pixel(image, x: 200, y: 150)
        XCTAssertGreaterThan(center.r, 240)
        let corner = pixel(image, x: 3, y: 3)
        XCTAssertLessThan(corner.r, 90, "corner should show the graphite canvas, got \(corner)")
        // Just inside the padding (30px) the card begins - but the rounded
        // corner is cut, so sample along the top edge midpoint instead.
        let cardEdge = pixel(image, x: 200, y: 32)
        XCTAssertGreaterThan(cardEdge.r, 240)
    }

    func testDisabledCanvasIsFullBleed() {
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = CameraFrameRenderer.render(
            source: source,
            camera: CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, zoom: 1),
            time: 0, outputSize: CGSize(width: 400, height: 300), cursor: nil, canvas: .off
        )
        XCTAssertGreaterThan(pixel(image, x: 1, y: 1).r, 240)
    }
}
#endif
