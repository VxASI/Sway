import AVFoundation
import AppKit
import Combine
import CoreImage
import Foundation
import SwayCapture
import SwayCore
import SwiftUI

/// Everything the export sheet lets the user choose. Translated into
/// `ExportOptions` when the export starts.
struct ExportSettings {
    enum SizePreset: String, CaseIterable, Identifiable {
        case original, landscape, vertical, square
        var id: String { rawValue }

        var label: String {
            switch self {
            case .original: return "Original"
            case .landscape: return "1920×1080"
            case .vertical: return "1080×1920"
            case .square: return "1080×1080"
            }
        }

        var size: CGSize? {
            switch self {
            case .original: return nil
            case .landscape: return CGSize(width: 1920, height: 1080)
            case .vertical: return CGSize(width: 1080, height: 1920)
            case .square: return CGSize(width: 1080, height: 1080)
            }
        }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case standard, high
        var id: String { rawValue }
        var label: String { self == .high ? "High" : "Standard" }
        /// Bits per pixel per frame, the usual H.264 sizing rule of thumb.
        var bitsPerPixel: Double { self == .high ? 0.15 : 0.07 }
    }

    enum FrameRate: String, CaseIterable, Identifiable {
        case original, fps30
        var id: String { rawValue }
        var label: String { self == .original ? "60 fps" : "30 fps" }
        var value: Int? { self == .original ? nil : 30 }
    }

    var sizePreset: SizePreset = .original
    var quality: Quality = .high
    var frameRate: FrameRate = .original
}

/// The editor's state: the recording, the edit being made on it, and the
/// preview player that renders that edit live.
@MainActor
final class EditorModel: ObservableObject {
    let bundle: SwayProjectBundle
    private(set) var project: SwayProject
    let track: CursorTrack
    let player: AVPlayer

    @Published private(set) var edit: SwayEdit
    @Published var playhead: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published var selectedSegmentID: UUID?
    @Published var projectName: String

    // Export flow.
    @Published var isExportSheetPresented = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published var exportedURL: URL?
    @Published private(set) var exportError: String?
    @Published var exportSettings = ExportSettings()
    @Published var errorMessage: String?

    private let generator = CameraPathGenerator()
    private let camera = CameraBox()
    private let canvas = CanvasBox()
    private let cursor = CursorBox()
    private let shapes: CursorShapeTrack
    private let shapeImages: [String: CGImage]
    let preview: PreviewSource
    private var timeObserver: Any?

    var duration: TimeInterval { project.duration }
    var segments: [EffectSegment] { edit.segments }
    var trimStart: TimeInterval { edit.trimStart }
    var trimEnd: TimeInterval { edit.trimEnd }
    var canvasStyle: CanvasStyle { edit.canvas }
    var cursorStyle: CursorStyle { edit.cursor }
    /// Whether this recording captured the system pointer shapes.
    var hasRecordedShapes: Bool { !shapes.isEmpty }
    var recordsKeyPresses: Bool { track.events.contains { $0.type == .keyDown } }

    var selectedSegment: EffectSegment? {
        edit.segments.first { $0.id == selectedSegmentID }
    }

    init(result: RecordingResult) {
        bundle = result.bundle
        project = result.project
        track = result.track
        edit = result.edit
        projectName = result.project.name
            ?? result.bundle.url.deletingPathExtension().lastPathComponent

        let asset = AVURLAsset(url: result.bundle.videoURL)
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        camera.path = generator.generate(
            track: result.track,
            duration: result.project.duration,
            segments: result.edit.segments
        )
        canvas.style = result.edit.canvas
        shapes = result.shapes
        shapeImages = CursorRenderer.loadShapeImages(for: result.shapes, in: result.bundle)
        cursor.renderer = CursorRenderer(
            style: result.edit.cursor,
            track: result.track,
            shapes: result.shapes,
            shapeImages: shapeImages,
            scale: result.project.geometry.scale
        )
        // The preview renders itself (see PreviewView); the player only
        // supplies frames and audio.
        preview = PreviewSource(
            player: player,
            item: item,
            camera: camera,
            cursor: cursor,
            canvas: canvas,
            captureSize: CGSize(
                width: result.project.geometry.pixelWidth,
                height: result.project.geometry.pixelHeight
            )
        )

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in self?.tick(seconds) }
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

    /// Bumped when a seek has actually landed, so the paused preview redraws
    /// with the new frame rather than the one that was current when the seek
    /// was requested.
    @Published private(set) var frameRevision = 0

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, edit.trimStart), edit.trimEnd)
        playhead = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in self?.frameRevision &+= 1 }
        }
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

    // MARK: - Segments

    /// Adds a segment of `kind` in the first free stretch of timeline at or
    /// after the playhead. A zoom segment starts focused on the cursor's
    /// position at that moment, which is almost always what was meant.
    func addSegment(kind: EffectKind) {
        let length = max(1.0, min(4, duration * 0.3))
        let minimum = 0.25
        guard let gap = firstFreeGap(from: playhead, minimum: minimum) else {
            errorMessage = "There is no room left on the timeline for another effect."
            return
        }
        let start = gap.lowerBound
        let end = min(gap.upperBound, start + length)
        var segment = EffectSegment(kind: kind, start: start, end: end)
        if kind == .zoom, let position = track.position(at: start) {
            segment.centerX = position.x
            segment.centerY = position.y
        }
        edit.segments = EffectSegment.resolved(edit.segments + [segment], duration: duration)
        selectedSegmentID = segment.id
        regenerateCamera()
        save()
    }

    /// Replaces the segment with the same ID. `movingEnd` picks which edge
    /// gives way when the segment is squeezed against its minimum length.
    func updateSegment(_ segment: EffectSegment, movingEnd: Bool = true) {
        guard let index = edit.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        var updated = segment.clamped(to: duration, movingEnd: movingEnd)
        // Respect the neighbors: a segment cannot be dragged over another.
        if index > 0 {
            updated.start = max(updated.start, edit.segments[index - 1].end)
        }
        if index < edit.segments.count - 1 {
            updated.end = min(updated.end, edit.segments[index + 1].start)
        }
        guard updated.duration >= 0.25 - 1e-9 else { return }
        edit.segments[index] = updated
        edit.segments.sort { $0.start < $1.start }
        regenerateCamera()
    }

    /// Slides a segment to a new start, keeping its length and stopping at
    /// its neighbors and the recording's ends instead of shrinking it.
    func moveSegment(id: UUID, toStart start: TimeInterval, duration length: TimeInterval) {
        guard let index = edit.segments.firstIndex(where: { $0.id == id }) else { return }
        let lower = index > 0 ? edit.segments[index - 1].end : 0
        let upper = index < edit.segments.count - 1 ? edit.segments[index + 1].start : duration
        guard upper - lower >= length else { return }
        var moved = edit.segments[index]
        moved.start = min(max(start, lower), upper - length)
        moved.end = moved.start + length
        guard moved != edit.segments[index] else { return }
        edit.segments[index] = moved
        regenerateCamera()
    }

    func removeSegment(id: UUID) {
        edit.segments.removeAll { $0.id == id }
        if selectedSegmentID == id { selectedSegmentID = nil }
        regenerateCamera()
        save()
    }

    private func firstFreeGap(
        from time: TimeInterval,
        minimum: TimeInterval
    ) -> ClosedRange<TimeInterval>? {
        let lower = max(edit.trimStart, 0)
        let upper = min(edit.trimEnd, duration)
        var edges: [(start: TimeInterval, end: TimeInterval)] = [(lower, lower)]
        edges += edit.segments.map { ($0.start, $0.end) }
        edges.append((upper, upper))

        for index in 0..<(edges.count - 1) {
            let gapStart = max(edges[index].end, lower)
            let gapEnd = min(edges[index + 1].start, upper)
            let start = max(gapStart, min(time, gapEnd - minimum))
            if gapEnd - start >= minimum {
                return start...gapEnd
            }
        }
        return nil
    }

    // MARK: - Canvas

    func setCanvas(_ style: CanvasStyle) {
        edit.canvas = style.clamped()
        canvas.style = edit.canvas
        if !isPlaying { seek(to: playhead) }
    }

    // MARK: - Cursor

    func setCursor(_ style: CursorStyle) {
        edit.cursor = style.clamped()
        cursor.renderer = CursorRenderer(
            style: edit.cursor,
            track: track,
            shapes: shapes,
            shapeImages: shapeImages,
            scale: project.geometry.scale
        )
        if !isPlaying { seek(to: playhead) }
    }

    // MARK: - Smart Focus

    enum SmartFocusMode: String, CaseIterable, Identifiable {
        case clicks, cursor
        var id: String { rawValue }
        var label: String { self == .clicks ? "Auto-focus on clicks" : "Auto-focus on cursor" }
    }

    /// Replaces the segments with ones generated from the recording itself.
    /// `.clicks` produces zoom shots anchored on each group of interactions,
    /// framed slightly above center and held long enough to read; `.cursor`
    /// produces follow-cursor segments over the same active stretches. The
    /// springs in the camera generator supply the fast-start, soft-landing
    /// motion and the ease back to wide framing.
    func applySmartFocus(mode: SmartFocusMode, zoom: Double) {
        let detected = FocusDetector().segments(for: track, duration: duration)
        guard !detected.isEmpty else {
            errorMessage = "No clicks, drags or scrolls were recorded, so there is nothing to focus on yet."
            return
        }
        let generated = detected.map { shot -> EffectSegment in
            switch mode {
            case .clicks:
                // Camera center sits a little below the target so the target
                // itself lands slightly above the middle of the frame.
                return EffectSegment(
                    kind: .zoom,
                    start: shot.start,
                    end: shot.end,
                    zoom: zoom,
                    centerX: shot.anchorX,
                    centerY: min(1, shot.anchorY + 0.06 / max(1, zoom))
                )
            case .cursor:
                return EffectSegment(
                    kind: .followCursor,
                    start: shot.start,
                    end: shot.end,
                    zoom: zoom,
                    smoothing: 0.6
                )
            }
        }
        edit.segments = EffectSegment.resolved(generated, duration: duration)
        selectedSegmentID = nil
        regenerateCamera()
        save()
    }

    func clearSegments() {
        edit.segments = []
        selectedSegmentID = nil
        regenerateCamera()
        save()
    }

    // MARK: - Trim

    func setTrimStart(_ time: TimeInterval) {
        edit.trimStart = min(max(0, time), max(0, edit.trimEnd - 0.25))
        if playhead < edit.trimStart { seek(to: edit.trimStart) }
    }

    func setTrimEnd(_ time: TimeInterval) {
        edit.trimEnd = max(min(duration, time), edit.trimStart + 0.25)
        if playhead > edit.trimEnd { seek(to: edit.trimEnd) }
    }

    // MARK: - Project name

    func commitProjectName() {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            projectName = project.name
                ?? bundle.url.deletingPathExtension().lastPathComponent
            return
        }
        projectName = trimmed
        guard project.name != trimmed else { return }
        project.name = trimmed
        do {
            try bundle.write(project: project)
        } catch {
            errorMessage = "Could not rename the project.\n\n\(error)"
        }
    }

    /// Rebuilds the camera path and refreshes the paused frame so the preview
    /// always shows the edit as it stands.
    private func regenerateCamera() {
        camera.path = generator.generate(track: track, duration: duration, segments: edit.segments)
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

    func export(settings: ExportSettings) {
        guard !isExporting else { return }
        commitProjectName()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = projectName + ".mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        save()
        pause()
        isExporting = true
        exportedURL = nil
        exportError = nil
        exportProgress = 0

        let outputSize = settings.sizePreset.size ?? CGSize(
            width: project.geometry.pixelWidth,
            height: project.geometry.pixelHeight
        )
        let fps = Double(settings.frameRate.value ?? 60)
        let bitRate = Int(outputSize.width * outputSize.height * fps * settings.quality.bitsPerPixel)
        var options = ExportOptions(
            size: settings.sizePreset.size,
            trim: edit.trimStart...edit.trimEnd,
            averageBitRate: bitRate,
            frameRate: settings.frameRate.value,
            canvas: edit.canvas
        )
        options.cursor = edit.cursor
        let exporter = CinematicExporter(bundle: bundle, options: options, camera: camera.path)
        Task {
            do {
                try await exporter.export(to: destination) { fraction in
                    Task { @MainActor [weak self] in self?.exportProgress = fraction }
                }
                self.exportedURL = destination
            } catch {
                self.exportError = "Export failed.\n\n\(error)"
            }
            self.isExporting = false
        }
    }

    func openExportedFile() {
        guard let exportedURL else { return }
        NSWorkspace.shared.open(exportedURL)
    }

    func revealExportedFile() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }
}

/// Lets the preview view, which draws on Metal's schedule, read the latest
/// camera path without any coordination with the main actor.
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


/// Same idea as `CameraBox`, for the canvas style.
final class CanvasBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = CanvasStyle.off

    var style: CanvasStyle {
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

/// Same idea again, for the cursor renderer, which is rebuilt whenever the
/// cursor style changes.
final class CursorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CursorRenderer?

    var renderer: CursorRenderer? {
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
