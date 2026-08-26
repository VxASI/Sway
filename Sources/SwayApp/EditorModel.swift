import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation
import SwayCapture
import SwayCore
import SwiftUI

/// The editor's state: the recording, the edit being made on it, and the
/// preview player that renders that edit live.
@MainActor
final class EditorModel: ObservableObject {
    let bundle: SwayProjectBundle
    let project: SwayProject
    let track: CursorTrack
    let player: AVPlayer

    @Published private(set) var edit: SwayEdit
    @Published var playhead: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isExporting = false
    @Published var exportedURL: URL?
    @Published var errorMessage: String?

    private let generator = CameraPathGenerator()
    private let camera = CameraBox()
    private var timeObserver: Any?

    var duration: TimeInterval { project.duration }
    var focus: FocusRange? { edit.focus }
    var trimStart: TimeInterval { edit.trimStart }
    var trimEnd: TimeInterval { edit.trimEnd }

    init(result: RecordingResult) {
        bundle = result.bundle
        project = result.project
        track = result.track
        edit = result.edit

        let asset = AVURLAsset(url: result.bundle.videoURL)
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        camera.path = generator.generate(
            track: result.track,
            duration: result.project.duration,
            focus: result.edit.focus
        )
        let cursor = CursorRenderer(
            options: ExportOptions(),
            track: result.track,
            scale: result.project.geometry.scale
        )
        item.videoComposition = EditorModel.composition(
            asset: asset,
            size: CGSize(
                width: result.project.geometry.pixelWidth,
                height: result.project.geometry.pixelHeight
            ),
            camera: camera,
            cursor: cursor
        )

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        seek(to: edit.trimStart)
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        if playhead >= edit.trimEnd - 0.05 {
            seek(to: edit.trimStart)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, edit.trimStart), edit.trimEnd)
        playhead = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        playhead = seconds
        // Trimming is applied to playback as well, so preview matches export.
        if isPlaying && seconds >= edit.trimEnd {
            pause()
            seek(to: edit.trimEnd)
        }
    }

    // MARK: - Editing

    func setFocus(_ range: FocusRange?) {
        edit.focus = range?.clamped(to: duration)
        regenerateCamera()
    }

    func addFocus() {
        let length = max(1.5, min(4, duration * 0.4))
        let start = min(max(playhead, edit.trimStart), max(edit.trimStart, edit.trimEnd - length))
        setFocus(FocusRange(start: start, end: min(edit.trimEnd, start + length), zoom: 2))
    }

    func removeFocus() {
        setFocus(nil)
    }

    func setZoom(_ zoom: Double) {
        guard var range = edit.focus else { return }
        range.zoom = zoom
        setFocus(range)
    }

    func setTrimStart(_ time: TimeInterval) {
        edit.trimStart = min(max(0, time), max(0, edit.trimEnd - 0.25))
        if playhead < edit.trimStart { seek(to: edit.trimStart) }
    }

    func setTrimEnd(_ time: TimeInterval) {
        edit.trimEnd = max(min(duration, time), edit.trimStart + 0.25)
        if playhead > edit.trimEnd { seek(to: edit.trimEnd) }
    }

    /// Rebuilds the camera path and refreshes the paused frame so the preview
    /// always shows the edit as it stands.
    private func regenerateCamera() {
        camera.path = generator.generate(track: track, duration: duration, focus: edit.focus)
        if !isPlaying {
            seek(to: playhead)
        }
    }

    func save() {
        do {
            try bundle.write(edit: edit)
            try bundle.write(camera: camera.path)
        } catch {
            errorMessage = "Could not save the edit.\n\n\(error)"
        }
    }

    // MARK: - Export

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = bundle.url.deletingPathExtension().lastPathComponent + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        save()
        pause()
        isExporting = true
        let options = ExportOptions(trim: edit.trimStart...edit.trimEnd)
        let exporter = CinematicExporter(bundle: bundle, options: options, camera: camera.path)
        Task {
            do {
                try await exporter.export(to: destination)
                self.exportedURL = destination
            } catch {
                self.errorMessage = "Export failed.\n\n\(error)"
            }
            self.isExporting = false
        }
    }

    // MARK: - Preview composition

    private static func composition(
        asset: AVAsset,
        size: CGSize,
        camera: CameraBox,
        cursor: CursorRenderer
    ) -> AVVideoComposition {
        AVMutableVideoComposition(asset: asset) { request in
            let time = request.compositionTime.seconds
            let state = camera.path.state(at: time)
                ?? CameraKeyframe(time: time, centerX: 0.5, centerY: 0.5, zoom: 1)
            let image = CameraFrameRenderer.render(
                source: request.sourceImage,
                camera: state,
                time: time,
                outputSize: size,
                cursor: cursor
            )
            request.finish(with: image, context: nil)
        }
    }
}

/// Lets the preview composition, which runs on AVFoundation's own queue, read
/// the latest camera path without rebuilding the composition on every drag.
final class CameraBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = CameraPath(frameRate: 60, keyframes: [])

    var path: CameraPath {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
