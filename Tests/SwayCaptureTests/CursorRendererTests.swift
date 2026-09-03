#if os(macOS)
import CoreGraphics
import CoreImage
import XCTest
@testable import SwayCapture
@testable import SwayCore

final class CursorRendererTests: XCTestCase {
    private let context = CIContext()
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// A track that moves for the first 2 s, then sits still until 8 s, with
    /// a click at 1 s and key presses at 5 s.
    private func track() -> CursorTrack {
        var events: [CursorEvent] = []
        var t = 0.0
        while t <= 2 {
            events.append(CursorEvent(time: t, x: 0.2 + 0.3 * t / 2, y: 0.5, type: .move))
            t += 1.0 / 60
        }
        events.append(CursorEvent(time: 1.0, x: 0.35, y: 0.5, type: .leftMouseDown))
        events.append(CursorEvent(time: 5.0, x: 0.5, y: 0.5, type: .keyDown))
        events.append(CursorEvent(time: 5.2, x: 0.5, y: 0.5, type: .keyDown))
        events.append(CursorEvent(time: 8.0, x: 0.5, y: 0.5, type: .sample))
        return CursorTrack(events: events.sorted { $0.time < $1.time })
    }

    private func alphaAt(_ image: CIImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .BGRA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return bytes[3]
    }

    func testIdleHidesTheCursorAfterTheChosenDelay() {
        var style = CursorStyle.standard
        style.hideWhenIdle = true
        style.idleSeconds = 1
        let renderer = CursorRenderer(style: style, track: track(), scale: 1)

        XCTAssertEqual(renderer.visibility(at: 1.5), 1, accuracy: 1e-6, "moving: visible")
        XCTAssertEqual(renderer.visibility(at: 2.5), 1, accuracy: 1e-6, "still within the idle delay")
        XCTAssertEqual(renderer.visibility(at: 4.0), 0, accuracy: 1e-6, "idle: hidden")
        // Fades rather than snaps.
        let mid = renderer.visibility(at: 3.15)
        XCTAssertGreaterThan(mid, 0.05)
        XCTAssertLessThan(mid, 0.95)
    }

    func testTypingHidesTheCursorBriefly() {
        var style = CursorStyle.standard
        style.hideWhileTyping = true
        let renderer = CursorRenderer(style: style, track: track(), scale: 1)

        XCTAssertEqual(renderer.visibility(at: 4.9), 1, accuracy: 1e-6)
        XCTAssertLessThan(renderer.visibility(at: 5.5), 0.05, "hidden right after a key press")
        XCTAssertEqual(renderer.visibility(at: 7.0), 1, accuracy: 1e-6, "back once typing stops")
    }

    func testSmoothingLagsBehindTheRawPath() {
        var raw = CursorStyle.standard
        raw.smoothing = 0
        var smooth = CursorStyle.standard
        smooth.smoothing = 1
        let source = track()
        // Draw both onto a transparent frame and locate the arrow by its
        // leftmost opaque pixel along the cursor's row.
        func tipX(_ style: CursorStyle) -> Int? {
            let renderer = CursorRenderer(style: style, track: source, scale: 1)
            let image = renderer.draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 1.0)
            for x in 0..<Int(extent.width) where alphaAt(image, x: x, y: 150 - 2) > 100 {
                return x
            }
            return nil
        }
        let rawTip = tipX(raw)
        let smoothTip = tipX(smooth)
        XCTAssertNotNil(rawTip)
        XCTAssertNotNil(smoothTip)
        // The cursor moves right; a smoothed path trails, so its tip is left
        // of the raw one.
        XCTAssertLessThan(smoothTip ?? 0, rawTip ?? 0)
    }

    func testRecordedShapeIsDrawnWithItsHotspot() throws {
        // A 10x10 solid pointer image with the hotspot at its center.
        let size = 10
        let cg = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        cg.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let pointer = try XCTUnwrap(cg.makeImage())

        let shapes = CursorShapeTrack(
            shapes: [CursorShape(id: "s", fileName: "s.png", width: 10, height: 10, hotspotX: 5, hotspotY: 5)],
            changes: [CursorShapeChange(time: 0, shapeID: "s")]
        )
        var style = CursorStyle.standard
        style.size = 1
        style.smoothing = 0
        style.clickRings = false
        let renderer = CursorRenderer(
            style: style,
            track: CursorTrack(events: [CursorEvent(time: 0, x: 0.5, y: 0.5, type: .move)]),
            shapes: shapes, shapeImages: ["s": pointer], scale: 1
        )
        let image = renderer.draw(on: CIImage.empty().cropped(to: extent), fullExtent: extent, time: 0)
        // Cursor at (200, 150) in top-left coords; the square is centered on
        // it, so the pixel at the hotspot is drawn and one 8px away is not.
        XCTAssertGreaterThan(alphaAt(image, x: 200, y: 150), 200)
        XCTAssertEqual(alphaAt(image, x: 212, y: 150), 0)
    }

    func testHiddenCursorLeavesTheFrameUntouched() {
        var style = CursorStyle.standard
        style.isVisible = false
        let renderer = CursorRenderer(style: style, track: track(), scale: 1)
        let base = CIImage(color: .red).cropped(to: extent)
        let image = renderer.draw(on: base, fullExtent: extent, time: 1)
        XCTAssertTrue(image === base || image.extent == base.extent)
        XCTAssertEqual(alphaAt(image, x: 140, y: 148), 255)
    }
}

final class CursorShapeTrackTests: XCTestCase {
    func testShapeLookupAndRebase() {
        let track = CursorShapeTrack(
            shapes: [
                CursorShape(id: "a", fileName: "a.png", width: 1, height: 1, hotspotX: 0, hotspotY: 0),
                CursorShape(id: "b", fileName: "b.png", width: 1, height: 1, hotspotX: 0, hotspotY: 0)
            ],
            changes: [
                CursorShapeChange(time: 0.5, shapeID: "a"),
                CursorShapeChange(time: 3.0, shapeID: "b")
            ]
        )
        XCTAssertEqual(track.shape(at: 0)?.id, "a")
        XCTAssertEqual(track.shape(at: 2)?.id, "a")
        XCTAssertEqual(track.shape(at: 3)?.id, "b")
        XCTAssertEqual(track.shape(at: 10)?.id, "b")

        // Rebasing by 1s keeps the shape that was current at the new zero.
        let rebased = track.rebased(by: 1)
        XCTAssertEqual(rebased.changes.map(\.time), [0, 2])
        XCTAssertEqual(rebased.shape(at: 0)?.id, "a")
        XCTAssertEqual(rebased.shape(at: 2.5)?.id, "b")
    }

    func testEditRoundTripsCursorStyle() throws {
        var edit = SwayEdit(trimEnd: 5)
        edit.cursor.spotlight = true
        edit.cursor.size = 2
        let data = try JSONEncoder().encode(edit)
        let decoded = try JSONDecoder().decode(SwayEdit.self, from: data)
        XCTAssertEqual(decoded.cursor, edit.cursor)
        // Older edits without a cursor block get the default.
        let legacy = try JSONDecoder().decode(SwayEdit.self, from: Data(#"{"trimEnd":5,"segments":[]}"#.utf8))
        XCTAssertEqual(legacy.cursor, .standard)
    }
}
#endif
