#if os(macOS)
import AVFoundation
import Foundation
import SwayCore

/// Drives one recording end to end: starts the shared timebase, the screen
/// capture and the cursor tracker together, then writes a `.sway` bundle and
/// generates the camera path once recording stops.
public final class RecordingSession {
    public let bundle: SwayProjectBundle
    private let options: ScreenRecorderOptions
    private let cameraGenerator: CameraPathGenerator
    private let sampleHz: Double

    private var bridge: HostClockBridge?
    private var recorder: ScreenRecorder?
    private var tracker: GlobalCursorTracker?

    public init(
        bundleURL: URL,
        options: ScreenRecorderOptions = ScreenRecorderOptions(),
        cameraGenerator: CameraPathGenerator = CameraPathGenerator(),
        cursorSampleHz: Double = 20
    ) {
        self.bundle = SwayProjectBundle(url: bundleURL)
        self.options = options
        self.cameraGenerator = cameraGenerator
        self.sampleHz = cursorSampleHz
    }

    public func start() async throws {
        try bundle.createDirectory()

        // One clock for everything that follows.
        let bridge = HostClockBridge(timebase: .now())
        self.bridge = bridge

        let recorder = ScreenRecorder(outputURL: bundle.videoURL, options: options, bridge: bridge)
        try await recorder.start()
        self.recorder = recorder

        guard let geometry = recorder.geometry else {
            throw ScreenRecordingError.noDisplayAvailable
        }
        let tracker = GlobalCursorTracker(geometry: geometry, bridge: bridge, sampleHz: sampleHz)
        do {
            try tracker.start()
        } catch {
            _ = try? await recorder.stop()
            throw error
        }
        self.tracker = tracker
    }

    /// Stops capture, writes `project.json`, `cursor.json` and `camera.json`,
    /// and returns the finished project.
    @discardableResult
    public func stop() async throws -> SwayProject {
        guard let recorder, let tracker, let bridge else {
            throw ScreenRecordingError.notRecording
        }
        tracker.stop()
        let duration = try await recorder.stop()

        // Cursor events are stamped in timebase seconds; the movie starts at
        // its first presentation timestamp. Rebase the track so time 0 is the
        // first video frame.
        let offset = recorder.videoStartOffset
        var track = tracker.track()
        track.events = track.events
            .map { event in
                var shifted = event
                shifted.time -= offset
                return shifted
            }
            .filter { $0.time >= 0 && (duration <= 0 || $0.time <= duration) }

        let camera = cameraGenerator.generate(track: track, duration: duration)
        let geometry = recorder.geometry ?? CaptureGeometry(
            displayID: 0, x: 0, y: 0, width: 0, height: 0, pixelWidth: 0, pixelHeight: 0
        )
        let project = SwayProject(
            duration: duration,
            geometry: geometry,
            hasSystemAudio: options.capturesSystemAudio,
            hasMicrophoneAudio: false,
            startHostSeconds: bridge.timebase.startSeconds
        )
        try bundle.write(project: project, track: track, camera: camera)

        self.recorder = nil
        self.tracker = nil
        self.bridge = nil
        return project
    }
}
#endif
