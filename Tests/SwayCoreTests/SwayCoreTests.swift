import XCTest
@testable import SwayCore

final class CaptureGeometryTests: XCTestCase {
    // A secondary display placed to the left of and above the main one, at 2x.
    private let geometry = CaptureGeometry(
        displayID: 7,
        x: -1440,
        y: -200,
        width: 1440,
        height: 900,
        pixelWidth: 2880,
        pixelHeight: 1800
    )

    func testNormalizesGlobalPointIntoCaptureRect() {
        let point = geometry.normalize(globalX: -720, globalY: 250)
        XCTAssertEqual(point.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(point.y, 0.5, accuracy: 1e-9)
    }

    func testRoundTripsThroughDenormalize() {
        let point = geometry.normalize(globalX: -1000, globalY: 0)
        let global = geometry.denormalize(x: point.x, y: point.y)
        XCTAssertEqual(global.x, -1000, accuracy: 1e-9)
        XCTAssertEqual(global.y, 0, accuracy: 1e-9)
    }

    func testReportsBackingScaleAndOutOfBoundsPoints() {
        XCTAssertEqual(geometry.scale, 2, accuracy: 1e-9)
        let outside = geometry.normalize(globalX: 100, globalY: 250)
        XCTAssertFalse(geometry.contains(normalizedX: outside.x, normalizedY: outside.y))
    }
}

final class CursorTrackTests: XCTestCase {
    func testMergeDropsSamplesThatRepeatTheEventStream() {
        let tap = [
            CursorEvent(time: 0.0, x: 0.1, y: 0.1, type: .move),
            CursorEvent(time: 0.5, x: 0.4, y: 0.4, type: .move)
        ]
        let samples = [
            CursorEvent(time: 0.05, x: 0.1, y: 0.1, type: .sample),  // redundant
            CursorEvent(time: 0.55, x: 0.9, y: 0.9, type: .sample)   // real recovery
        ]
        let track = CursorTrack.merge(tapEvents: tap, samples: samples)
        XCTAssertEqual(track.events.count, 3)
        XCTAssertEqual(track.events.map(\.type), [.move, .move, .sample])
    }

    func testInterpolatesPositionBetweenEvents() {
        let track = CursorTrack(events: [
            CursorEvent(time: 0, x: 0, y: 0, type: .move),
            CursorEvent(time: 1, x: 1, y: 0.5, type: .move)
        ])
        let point = track.position(at: 0.25)
        XCTAssertEqual(point?.x ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(point?.y ?? -1, 0.125, accuracy: 1e-9)
    }

    func testResamplingIsUniformAndClampsAtEdges() {
        let track = CursorTrack(events: [
            CursorEvent(time: 0, x: 0, y: 0, type: .move),
            CursorEvent(time: 1, x: 1, y: 1, type: .move)
        ])
        let samples = track.resampled(hz: 10)
        XCTAssertEqual(samples.count, 11)
        XCTAssertEqual(samples[5].x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(samples.last?.x ?? -1, 1, accuracy: 1e-6)
    }

    func testBufferDrainIsEmptyAfterwards() {
        let buffer = CursorEventBuffer()
        buffer.append(CursorEvent(time: 0, x: 0, y: 0, type: .move))
        XCTAssertEqual(buffer.drain().count, 1)
        XCTAssertTrue(buffer.snapshot().isEmpty)
    }
}

final class FocusDetectorTests: XCTestCase {
    func testGroupsNearbyClicksIntoOneShot() {
        let track = CursorTrack(events: [
            CursorEvent(time: 1.0, x: 0.30, y: 0.30, type: .leftMouseDown),
            CursorEvent(time: 1.8, x: 0.33, y: 0.31, type: .leftMouseDown),
            CursorEvent(time: 2.6, x: 0.35, y: 0.33, type: .leftMouseDown)
        ])
        let segments = FocusDetector().segments(for: track, duration: 10)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].interactionCount, 3)
        XCTAssertEqual(segments[0].anchorX, 0.3266, accuracy: 0.001)
    }

    func testSplitsClicksThatAreFarApartInSpaceOrTime() {
        let track = CursorTrack(events: [
            CursorEvent(time: 1.0, x: 0.1, y: 0.1, type: .leftMouseDown),
            CursorEvent(time: 1.5, x: 0.9, y: 0.9, type: .leftMouseDown),
            CursorEvent(time: 9.0, x: 0.9, y: 0.9, type: .leftMouseDown)
        ])
        let segments = FocusDetector().segments(for: track, duration: 12)
        XCTAssertEqual(segments.count, 3)
    }

    func testEnforcesMinimumShotDuration() {
        let track = CursorTrack(events: [
            CursorEvent(time: 5.0, x: 0.5, y: 0.5, type: .leftMouseDown)
        ])
        let config = FocusDetectorConfig(minimumDuration: 3.0)
        let segments = FocusDetector(config: config).segments(for: track, duration: 30)
        XCTAssertEqual(segments.count, 1)
        XCTAssertGreaterThanOrEqual(segments[0].duration, 3.0)
    }

    func testIgnoresPureMovement() {
        let track = CursorTrack(events: [
            CursorEvent(time: 0, x: 0.1, y: 0.1, type: .move),
            CursorEvent(time: 1, x: 0.6, y: 0.6, type: .move)
        ])
        XCTAssertTrue(FocusDetector().segments(for: track, duration: 2).isEmpty)
    }
}

final class CameraPathTests: XCTestCase {
    private func clickTrack() -> CursorTrack {
        CursorTrack(events: [
            CursorEvent(time: 0.0, x: 0.5, y: 0.5, type: .move),
            CursorEvent(time: 2.0, x: 0.30, y: 0.30, type: .move),
            CursorEvent(time: 2.2, x: 0.30, y: 0.30, type: .leftMouseDown),
            CursorEvent(time: 2.3, x: 0.30, y: 0.30, type: .leftMouseUp),
            CursorEvent(time: 8.0, x: 0.50, y: 0.50, type: .move)
        ])
    }

    func testZoomsInAroundInteractionAndBackOutAfterwards() {
        let path = CameraPathGenerator().generate(track: clickTrack(), duration: 8)
        XCTAssertFalse(path.keyframes.isEmpty)

        func zoom(at time: TimeInterval) -> Double {
            path.keyframes.min(by: { abs($0.time - time) < abs($1.time - time) })?.zoom ?? 0
        }
        XCTAssertEqual(zoom(at: 0.2), 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(zoom(at: 3.0), 1.3)
        XCTAssertEqual(zoom(at: 7.9), 1.0, accuracy: 0.1)
    }

    func testCameraMovesTowardTheClickWithoutLeavingTheFrame() {
        let path = CameraPathGenerator().generate(track: clickTrack(), duration: 8)
        let focused = path.keyframes.first { $0.time >= 3.0 && $0.time <= 3.2 }
        XCTAssertNotNil(focused)
        XCTAssertLessThan(focused!.centerX, 0.5)
        XCTAssertLessThan(focused!.centerY, 0.5)

        for keyframe in path.keyframes {
            let half = 0.5 / keyframe.zoom
            XCTAssertGreaterThanOrEqual(keyframe.centerX, half - 1e-6)
            XCTAssertLessThanOrEqual(keyframe.centerX, 1 - half + 1e-6)
            XCTAssertGreaterThanOrEqual(keyframe.centerY, half - 1e-6)
            XCTAssertLessThanOrEqual(keyframe.centerY, 1 - half + 1e-6)
        }
    }

    func testCameraStaysStillWhenNothingHappens() {
        let track = CursorTrack(events: [
            CursorEvent(time: 0, x: 0.5, y: 0.5, type: .move),
            CursorEvent(time: 5, x: 0.52, y: 0.51, type: .move)
        ])
        let path = CameraPathGenerator().generate(track: track, duration: 5)
        for keyframe in path.keyframes {
            XCTAssertEqual(keyframe.zoom, 1.0, accuracy: 1e-6)
            XCTAssertEqual(keyframe.centerX, 0.5, accuracy: 1e-6)
        }
    }

    func testPathIsSmoothFrameToFrame() {
        let path = CameraPathGenerator().generate(track: clickTrack(), duration: 8)
        for (previous, next) in zip(path.keyframes, path.keyframes.dropFirst()) {
            XCTAssertLessThan(abs(next.centerX - previous.centerX), 0.02)
            XCTAssertLessThan(abs(next.zoom - previous.zoom), 0.05)
        }
    }
}

final class SpringTests: XCTestCase {
    func testCriticallyDampedSpringSettlesWithoutOvershoot() {
        var spring = Spring(value: 0, stiffness: 60)
        var maxValue = 0.0
        for _ in 0..<240 {
            spring.advance(to: 1, dt: 1.0 / 60)
            maxValue = max(maxValue, spring.value)
        }
        XCTAssertEqual(spring.value, 1, accuracy: 0.01)
        XCTAssertLessThanOrEqual(maxValue, 1.02)
    }
}

final class TimebaseTests: XCTestCase {
    func testHostClockIsMonotonic() {
        let first = Timebase.hostSeconds()
        let second = Timebase.hostSeconds()
        XCTAssertGreaterThanOrEqual(second, first)
    }

    func testRelativeTimeIsAnOffsetFromStart() {
        let timebase = Timebase(startSeconds: 100)
        XCTAssertEqual(timebase.relative(toHostSeconds: 104.826), 4.826, accuracy: 1e-9)
    }
}

final class ProjectBundleTests: XCTestCase {
    func testWritesAndReadsBundle() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).sway")
        defer { try? FileManager.default.removeItem(at: url) }

        let bundle = SwayProjectBundle(url: url)
        let geometry = CaptureGeometry(
            displayID: 1, x: 0, y: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964
        )
        let track = CursorTrack(events: [
            CursorEvent(time: 0.5, x: 0.25, y: 0.75, type: .leftMouseDown)
        ])
        let project = SwayProject(
            duration: 3,
            geometry: geometry,
            hasSystemAudio: true,
            hasMicrophoneAudio: false,
            startHostSeconds: 1234.5
        )
        let camera = CameraPathGenerator().generate(track: track, duration: 3)
        try bundle.write(project: project, track: track, camera: camera)

        XCTAssertEqual(try bundle.readProject().geometry, geometry)
        XCTAssertEqual(try bundle.readCursorTrack(), track)
        XCTAssertEqual(try bundle.readCameraPath().keyframes.count, camera.keyframes.count)
    }
}
