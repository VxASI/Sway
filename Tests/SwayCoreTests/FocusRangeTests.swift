import XCTest
@testable import SwayCore

private func movingTrack(duration: TimeInterval, hz: Double = 60) -> CursorTrack {
    var events: [CursorEvent] = []
    var t: TimeInterval = 0
    while t <= duration {
        // Sweeps diagonally across the capture, well inside the frame.
        let progress = t / duration
        events.append(
            CursorEvent(time: t, x: 0.2 + 0.6 * progress, y: 0.3 + 0.4 * progress, type: .move)
        )
        t += 1 / hz
    }
    return CursorTrack(events: events)
}

final class FocusRangeTests: XCTestCase {
    func testClampKeepsRangeInsideRecording() {
        let range = FocusRange(start: -2, end: 20, zoom: 9).clamped(to: 10)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 10)
        XCTAssertEqual(range.zoom, 6)
    }

    func testClampEnforcesMinimumDuration() {
        let range = FocusRange(start: 4, end: 4.01).clamped(to: 10, minimumDuration: 0.5)
        XCTAssertEqual(range.duration, 0.5, accuracy: 1e-9)
    }

    func testInitialEditProposesRangeAroundInteractions() {
        var events = movingTrack(duration: 10).events
        events.append(CursorEvent(time: 6.0, x: 0.6, y: 0.5, type: .leftMouseDown))
        events.append(CursorEvent(time: 6.4, x: 0.61, y: 0.51, type: .leftMouseDown))
        let edit = SwayEdit.initial(duration: 10, track: CursorTrack(events: events.sorted { $0.time < $1.time }))

        let focus = try? XCTUnwrap(edit.focus)
        XCTAssertEqual(edit.trimStart, 0)
        XCTAssertEqual(edit.trimEnd, 10)
        XCTAssertNotNil(focus)
        XCTAssertTrue(focus?.contains(6.2) == true)
    }

    func testInitialEditStillProposesARangeWithoutInteractions() throws {
        let edit = SwayEdit.initial(duration: 8, track: movingTrack(duration: 8))
        let focus = try XCTUnwrap(edit.focus)
        XCTAssertGreaterThan(focus.duration, 0)
        XCTAssertLessThanOrEqual(focus.end, 8)
    }
}

final class FocusRangeCameraTests: XCTestCase {
    private let duration: TimeInterval = 10
    private lazy var track = movingTrack(duration: duration)

    func testCameraIsCenteredAtRestOutsideTheRange() throws {
        let range = FocusRange(start: 4, end: 7, zoom: 2)
        let path = CameraPathGenerator().generate(track: track, duration: duration, focus: range)

        let before = try XCTUnwrap(path.state(at: 1))
        XCTAssertEqual(before.zoom, 1, accuracy: 0.01)
        XCTAssertEqual(before.centerX, 0.5, accuracy: 0.01)
        XCTAssertEqual(before.centerY, 0.5, accuracy: 0.01)

        // Well after the range the camera has eased back to the full frame.
        let after = try XCTUnwrap(path.state(at: 9.5))
        XCTAssertEqual(after.zoom, 1, accuracy: 0.02)
        XCTAssertEqual(after.centerX, 0.5, accuracy: 0.02)
    }

    func testCameraReachesTheRangeZoomAndFollowsTheCursor() throws {
        let range = FocusRange(start: 4, end: 7, zoom: 2.5)
        let path = CameraPathGenerator().generate(track: track, duration: duration, focus: range)

        let inside = try XCTUnwrap(path.state(at: 6))
        XCTAssertEqual(inside.zoom, 2.5, accuracy: 0.05)

        let cursor = try XCTUnwrap(track.position(at: 6))
        // Dead zone plus clamping keep the camera near, not exactly on, the cursor.
        XCTAssertEqual(inside.centerX, cursor.x, accuracy: 0.15)
        XCTAssertEqual(inside.centerY, cursor.y, accuracy: 0.15)
    }

    func testZoomTransitionsAreSmooth() {
        let range = FocusRange(start: 4, end: 7, zoom: 3)
        let path = CameraPathGenerator().generate(track: track, duration: duration, focus: range)

        var previous = path.keyframes[0]
        for keyframe in path.keyframes.dropFirst() {
            XCTAssertLessThan(abs(keyframe.zoom - previous.zoom), 0.15, "zoom jumped at \(keyframe.time)")
            XCTAssertLessThan(abs(keyframe.centerX - previous.centerX), 0.05)
            XCTAssertLessThan(abs(keyframe.centerY - previous.centerY), 0.05)
            previous = keyframe
        }
    }

    func testViewportNeverLeavesTheCapturedFrame() {
        // A cursor that runs into the corners is the case that would expose the
        // area outside the capture if the camera were not clamped.
        var events: [CursorEvent] = []
        var t: TimeInterval = 0
        while t <= duration {
            events.append(CursorEvent(time: t, x: t < 5 ? 0.01 : 0.99, y: t < 5 ? 0.02 : 0.98, type: .move))
            t += 1 / 60
        }
        let path = CameraPathGenerator().generate(
            track: CursorTrack(events: events),
            duration: duration,
            focus: FocusRange(start: 1, end: 9, zoom: 2)
        )

        for keyframe in path.keyframes {
            let half = 0.5 / keyframe.zoom
            XCTAssertGreaterThanOrEqual(keyframe.centerX, half - 1e-9)
            XCTAssertLessThanOrEqual(keyframe.centerX, 1 - half + 1e-9)
            XCTAssertGreaterThanOrEqual(keyframe.centerY, half - 1e-9)
            XCTAssertLessThanOrEqual(keyframe.centerY, 1 - half + 1e-9)
        }
    }

    func testNoRangeMeansNoZoom() {
        let path = CameraPathGenerator().generate(track: track, duration: duration, focus: nil)
        XCTAssertFalse(path.keyframes.isEmpty)
        for keyframe in path.keyframes {
            XCTAssertEqual(keyframe.zoom, 1, accuracy: 1e-6)
            XCTAssertEqual(keyframe.centerX, 0.5, accuracy: 1e-6)
        }
    }

    func testRangeStillZoomsWithoutCursorData() throws {
        let path = CameraPathGenerator().generate(
            track: CursorTrack(events: []),
            duration: duration,
            focus: FocusRange(start: 2, end: 8, zoom: 2)
        )
        let inside = try XCTUnwrap(path.state(at: 5))
        XCTAssertEqual(inside.zoom, 2, accuracy: 0.05)
        XCTAssertEqual(inside.centerX, 0.5, accuracy: 1e-6)
    }
}
