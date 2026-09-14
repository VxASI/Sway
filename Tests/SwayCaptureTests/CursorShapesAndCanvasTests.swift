#if os(macOS)
import CoreGraphics
import CoreImage
import XCTest
@testable import SwayCapture
@testable import SwayCore

final class CursorShapesAndCanvasTests: XCTestCase {
    private let context = CIContext()
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 200)

    /// BGRA at a top-left-origin pixel coordinate.
    private func pixel(_ image: CIImage, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: x, y: Int(extent.height) - 1 - y, width: 1, height: 1),
            format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    private func renderer(_ style: CursorStyle, shapes: CursorShapeTrack = CursorShapeTrack(),
                          shapeImages: [String: CGImage] = [:], customImage: CGImage? = nil) -> CursorRenderer {
        var style = style
        style.smoothing = 0
        style.clickRings = false
        style.size = 1
        return CursorRenderer(
            style: style,
            track: CursorTrack(events: [CursorEvent(time: 0, x: 0.5, y: 0.5, type: .move)]),
            shapes: shapes, shapeImages: shapeImages, customImage: customImage, scale: 1
        )
    }

    private func solid(_ w: Int, _ h: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let cg = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        cg.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(cg.makeImage())
    }

    func testDotIsCenteredOnTheHotspotAndTinted() {
        var style = CursorStyle.standard
        style.shape = .dot
        style.tint = .orange
        let image = renderer(style).draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 0)
        let center = pixel(image, x: 100, y: 100)
        XCTAssertGreaterThan(center.a, 200)
        XCTAssertGreaterThan(center.r, 200)
        XCTAssertLessThan(center.b, 120, "orange, not white")
        // Symmetric: equally opaque 4px left and right of the hotspot.
        XCTAssertEqual(pixel(image, x: 96, y: 100).a, pixel(image, x: 104, y: 100).a, accuracy: 30)
    }

    func testHaloRingSurroundsTheHotspot() {
        var style = CursorStyle.standard
        style.shape = .halo
        style.tint = .blue
        let image = renderer(style).draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 0)
        // Ring radius is 0.9 * 24 = ~21.6px; the stroke sits near it.
        let onRing = pixel(image, x: 100 + 21, y: 100)
        XCTAssertGreaterThan(onRing.a, 90, "ring stroke should be visible at the radius")
        let farOutside = pixel(image, x: 100 + 40, y: 100)
        XCTAssertEqual(farOutside.a, 0)
    }

    func testRecordedPointerIsInvertedToLightByDefault() throws {
        let black = try solid(10, 10, red: 0, green: 0, blue: 0)
        let shapes = CursorShapeTrack(
            shapes: [CursorShape(id: "s", fileName: "s.png", width: 10, height: 10, hotspotX: 5, hotspotY: 5)],
            changes: [CursorShapeChange(time: 0, shapeID: "s")]
        )
        var style = CursorStyle.standard
        style.shape = .recorded
        let light = renderer(style, shapes: shapes, shapeImages: ["s": black])
            .draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 0)
        XCTAssertGreaterThan(pixel(light, x: 100, y: 100).r, 230, "light: black pointer becomes white")

        style.recordedColor = .dark
        let dark = renderer(style, shapes: shapes, shapeImages: ["s": black])
            .draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 0)
        XCTAssertLessThan(pixel(dark, x: 100, y: 100).r, 25, "dark: pointer kept as shown")
        XCTAssertEqual(pixel(dark, x: 100, y: 100).a, 255)
    }

    func testCustomPointerUsesItsHotspotAndWidth() throws {
        let green = try solid(40, 20, red: 0, green: 1, blue: 0)
        var style = CursorStyle.standard
        style.shape = .custom
        style.customImage = CursorStyle.CustomImage(fileName: "x.png", hotspotX: 0.5, hotspotY: 0.5, pointWidth: 40)
        let image = renderer(style, customImage: green)
            .draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 0)
        // Centered 40x20 rect on (100, 100): inside at (100,100) and (118,108), outside at (122,100).
        XCTAssertGreaterThan(pixel(image, x: 100, y: 100).g, 200)
        XCTAssertGreaterThan(pixel(image, x: 118, y: 108).g, 200)
        XCTAssertEqual(pixel(image, x: 122, y: 100).a, 0)
        XCTAssertEqual(pixel(image, x: 100, y: 112).a, 0)
    }

    func testCanvasCardKeepsTheSourceAspectSoNothingIsCropped() {
        // A wide 2:1 recording on a square canvas: the card must be 2:1 too,
        // letterboxed, and show the source's very top and bottom rows.
        let w = 400, h = 200
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        // Mark the top and bottom source rows in green (CI: bottom row is y=0).
        let greenTop = CIImage(color: .green).cropped(to: CGRect(x: 0, y: h - 4, width: w, height: 4))
        let greenBottom = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: w, height: 4))
        let marked = greenTop.composited(over: greenBottom.composited(over: source))

        let output = CGSize(width: 400, height: 400)
        let style = CanvasStyle(isEnabled: true, padding: 0.05, cornerRadius: 0, shadow: 0, background: .graphite)
        let rect = style.contentRect(in: output, contentAspect: 2)
        XCTAssertEqual(rect.width / rect.height, 2, accuracy: 0.02)
        XCTAssertEqual(rect.midX, 200, accuracy: 1)
        XCTAssertEqual(rect.midY, 200, accuracy: 1)

        let image = CameraFrameRenderer.render(
            source: marked, camera: CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, zoom: 1),
            time: 0, outputSize: output, cursor: nil, canvas: style
        )
        // Sample the card's top and bottom rows (top-left coords).
        let cardTop = Int(output.height - rect.maxY) + 1
        let cardBottom = Int(output.height - rect.minY) - 2
        func px(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8) {
            var b = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &b, rowBytes: 4,
                           bounds: CGRect(x: x, y: Int(output.height) - 1 - y, width: 1, height: 1),
                           format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (b[2], b[1])
        }
        XCTAssertGreaterThan(px(200, cardTop).g, 200, "source top row visible")
        XCTAssertLessThan(px(200, cardTop).r, 80)
        XCTAssertGreaterThan(px(200, cardBottom).g, 200, "source bottom row visible")
        XCTAssertLessThan(px(200, cardBottom).r, 80)
    }

    func testCustomCanvasBackgroundIsUsed() throws {
        let blue = try solid(50, 50, red: 0, green: 0, blue: 1)
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var style = CanvasStyle(isEnabled: true, padding: 0.2, cornerRadius: 0, shadow: 0, background: .custom)
        style.customImage = "x.png"
        style.customBlur = 0
        let image = CameraFrameRenderer.render(
            source: source, camera: CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, zoom: 1),
            time: 0, outputSize: CGSize(width: 200, height: 200), cursor: nil, canvas: style, canvasImage: blue
        )
        let corner = pixel(image, x: 5, y: 5)
        XCTAssertGreaterThan(corner.b, 200, "custom image should fill the padding")
        XCTAssertLessThan(corner.r, 40)
        XCTAssertGreaterThan(pixel(image, x: 100, y: 100).r, 240, "recording in the middle")
    }
}
#endif
