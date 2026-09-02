#if os(macOS)
@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import SwayCore

public enum ExportError: Error, CustomStringConvertible {
    case noVideoTrack
    case readerSetupFailed(String)
    case writerSetupFailed(String)

    public var description: String {
        switch self {
        case .noVideoTrack: return "The recording has no video track."
        case .readerSetupFailed(let reason): return "Could not read the recording: \(reason)"
        case .writerSetupFailed(let reason): return "Could not write the export: \(reason)"
        }
    }
}

public struct ExportOptions: Sendable {
    /// Output size in pixels. `nil` keeps the recorded size. A different
    /// aspect ratio than the capture is honored by aspect-filling: the camera
    /// viewport is cropped, centered on the camera, never stretched.
    public var size: CGSize?
    public var drawsCursor: Bool
    /// Cursor size relative to the recorded scale (1 = macOS default size).
    public var cursorScale: Double
    public var drawsClickRings: Bool
    public var clickRingDuration: TimeInterval
    /// Portion of the recording to export. `nil` exports all of it. Audio is
    /// kept and re-timed to the trimmed range.
    public var trim: ClosedRange<TimeInterval>?
    public var codec: AVVideoCodecType
    /// Video bit rate. `nil` lets the codec pick a default.
    public var averageBitRate: Int?
    /// Caps the output frame rate by skipping source frames. `nil` keeps the
    /// source timing.
    public var frameRate: Int?

    public init(
        size: CGSize? = nil,
        drawsCursor: Bool = true,
        cursorScale: Double = 1.4,
        drawsClickRings: Bool = true,
        clickRingDuration: TimeInterval = 0.45,
        trim: ClosedRange<TimeInterval>? = nil,
        codec: AVVideoCodecType = .h264,
        averageBitRate: Int? = nil,
        frameRate: Int? = nil
    ) {
        self.trim = trim
        self.size = size
        self.drawsCursor = drawsCursor
        self.cursorScale = cursorScale
        self.drawsClickRings = drawsClickRings
        self.clickRingDuration = clickRingDuration
        self.codec = codec
        self.averageBitRate = averageBitRate
        self.frameRate = frameRate
    }
}

/// Renders a `.sway` bundle into a finished movie: the camera path becomes a
/// moving crop of the source frames, and the cursor is drawn back in from the
/// recorded event stream (the capture itself has no cursor baked in).
public final class CinematicExporter {
    private let bundle: SwayProjectBundle
    private let options: ExportOptions
    private let overrideCamera: CameraPath?
    private let context = CIContext()

    /// `camera` overrides the path stored in the bundle, which is how the
    /// editor exports the range the user is currently looking at.
    public init(
        bundle: SwayProjectBundle,
        options: ExportOptions = ExportOptions(),
        camera: CameraPath? = nil
    ) {
        self.bundle = bundle
        self.options = options
        self.overrideCamera = camera
    }

    public func export(
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let project = try bundle.readProject()
        let track = try bundle.readCursorTrack()
        let camera = overrideCamera
            ?? (try? bundle.readCameraPath())
            ?? CameraPathGenerator().generate(track: track, duration: project.duration)
        let trim = options.trim
        let exportedDuration = max(
            0.001,
            (trim?.upperBound ?? project.duration) - (trim?.lowerBound ?? 0)
        )

        let asset = AVURLAsset(url: bundle.videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let sourceSize = try await videoTrack.load(.naturalSize)
        let outputSize = options.size ?? sourceSize

        let reader = try AVAssetReader(asset: asset)
        if let trim {
            // The reader trims both tracks at the source, so audio survives a
            // trimmed export; the samples are re-timed to the new zero below.
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: trim.lowerBound, preferredTimescale: 600),
                duration: CMTime(seconds: exportedDuration, preferredTimescale: 600)
            )
        }
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.readerSetupFailed("video output rejected")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM
            ])
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height)
        ]
        if let bitRate = options.averageBitRate {
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitRate]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height)
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerSetupFailed("video input rejected")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: 192_000
                ]
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw ExportError.readerSetupFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw ExportError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let renderer = CursorRenderer(
            options: options,
            track: track,
            scale: project.geometry.scale
        )
        let trimStart = trim?.lowerBound ?? 0

        // Both tracks are pumped at the same time. AVAssetWriter interleaves
        // its inputs and stops accepting video once it gets too far ahead of
        // the audio, so draining video first and audio second deadlocks.
        //
        // Each pump also reads one sample ahead. The writer only calls back
        // while it wants more data, and after the final append it may never
        // call again - so end-of-stream has to be discovered right after that
        // append, not on the next callback that never comes.
        let videoQueue = DispatchQueue(label: "ai.sway.export.video")
        let audioQueue = DispatchQueue(label: "ai.sway.export.audio")
        let audioOffset = CMTime(seconds: -trimStart, preferredTimescale: 600)

        @Sendable func pumpVideo() async {
            // Constant-frame-rate output. ScreenCaptureKit only delivers a
            // frame when the screen changes, so a recording of a mostly
            // static screen is effectively ~10 fps. Rendering only on source
            // frames would make the camera moves and the drawn cursor stutter
            // at that rate, so the output clock ticks at a fixed rate and the
            // most recent source frame is held between changes.
            let outputStep = 1.0 / Double(options.frameRate ?? 60)
            let outputEnd = trim?.upperBound ?? project.duration
            var finished = false
            var outputTime = trimStart
            var current: CVPixelBuffer?
            var pending = videoOutput.copyNextSampleBuffer()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                func finish() {
                    guard !finished else { return }
                    finished = true
                    videoInput.markAsFinished()
                    continuation.resume()
                }
                videoInput.requestMediaDataWhenReady(on: videoQueue) {
                    while videoInput.isReadyForMoreMediaData, !finished {
                        // Advance the source to the newest frame at or before
                        // this output tick. The recorder starts the movie's
                        // timeline at the first captured frame, so asset time
                        // is recording time - the same timeline the cursor
                        // track and camera path use.
                        while let sample = pending,
                              CMSampleBufferGetPresentationTimeStamp(sample).seconds <= outputTime + outputStep / 2 {
                            if let buffer = CMSampleBufferGetImageBuffer(sample) { current = buffer }
                            pending = videoOutput.copyNextSampleBuffer()
                        }
                        // Before the first frame, show the first frame.
                        if current == nil, let sample = pending {
                            current = CMSampleBufferGetImageBuffer(sample)
                        }
                        guard let source = current else { return finish() }
                        if outputTime > outputEnd + outputStep / 2 { return finish() }

                        let state = camera.state(at: outputTime)
                            ?? CameraKeyframe(time: outputTime, centerX: 0.5, centerY: 0.5, zoom: 1)
                        if let rendered = self.renderFrame(
                            pixelBuffer: source,
                            camera: state,
                            time: outputTime,
                            outputSize: outputSize,
                            renderer: renderer,
                            pool: adaptor.pixelBufferPool
                        ) {
                            adaptor.append(
                                rendered,
                                withPresentationTime: CMTime(
                                    seconds: max(0, outputTime - trimStart),
                                    preferredTimescale: 600
                                )
                            )
                            progress?(min(0.98, max(0, (outputTime - trimStart) / exportedDuration)))
                        }
                        outputTime += outputStep
                    }
                }
            }
        }

        let audioPair = audioInput.flatMap { input in audioOutput.map { (input, $0) } }
        @Sendable func pumpAudio() async {
            guard let (audioInput, audioOutput) = audioPair else { return }
            var finished = false
            var pending = audioOutput.copyNextSampleBuffer()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                func finish() {
                    guard !finished else { return }
                    finished = true
                    audioInput.markAsFinished()
                    continuation.resume()
                }
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData, !finished {
                        guard let sample = pending else { return finish() }
                        pending = audioOutput.copyNextSampleBuffer()
                        // Align audio with the trimmed video's new zero.
                        let shifted = trimStart > 0
                            ? CinematicExporter.retimed(sample, by: audioOffset) ?? sample
                            : sample
                        audioInput.append(shifted)
                    }
                    if pending == nil { finish() }
                }
            }
        }

        async let video: Void = pumpVideo()
        async let audio: Void = pumpAudio()
        _ = await (video, audio)

        await writer.finishWriting()
        if writer.status == .failed, let error = writer.error {
            throw error
        }
        progress?(1)
    }

    /// A copy of `sample` with its presentation timestamp shifted by `offset`.
    private static func retimed(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        )
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count
        )
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeAdd(
                timing[index].presentationTimeStamp, offset
            )
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, offset)
            }
        }
        var shifted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &shifted
        )
        return shifted
    }

    private func renderFrame(
        pixelBuffer: CVPixelBuffer,
        camera: CameraKeyframe,
        time: TimeInterval,
        outputSize: CGSize,
        renderer: CursorRenderer,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        let image = CameraFrameRenderer.render(
            source: CIImage(cvPixelBuffer: pixelBuffer),
            camera: camera,
            time: time,
            outputSize: outputSize,
            cursor: renderer
        )

        var output: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        }
        if output == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(outputSize.width),
                Int(outputSize.height),
                kCVPixelFormatType_32BGRA,
                nil,
                &output
            )
        }
        guard let output else { return nil }
        context.render(image, to: output)
        return output
    }
}

/// Draws the cursor and click feedback into a frame, in source pixel space.
/// Shared by the exporter and the editor's live preview, so what the user sees
/// while scrubbing is what gets rendered.
public struct CursorRenderer {
    let options: ExportOptions
    let track: CursorTrack
    let scale: Double
    private let clickTimes: [TimeInterval]
    /// The arrow, rasterized once at the origin; each frame only translates it.
    private let arrow: CIImage?

    public init(options: ExportOptions, track: CursorTrack, scale: Double) {
        self.options = options
        self.track = track
        self.scale = scale
        self.clickTimes = track.events.filter { $0.type.isClickDown }.map(\.time)
        self.arrow = CursorRenderer.rasterizeArrow(size: 24.0 * scale * options.cursorScale)
    }

    /// Cursor coordinates are normalized to the whole capture, so the overlay
    /// is placed in full-frame pixel space and the caller crops afterwards.
    public func draw(on image: CIImage, fullExtent: CGRect, time: TimeInterval) -> CIImage {
        guard options.drawsCursor, let position = track.position(at: time) else { return image }
        // CoreImage's origin is bottom-left; the track's is top-left.
        let pixelX = fullExtent.origin.x + position.x * fullExtent.width
        let pixelY = fullExtent.origin.y + (1 - position.y) * fullExtent.height
        let cursorSize = 24.0 * scale * options.cursorScale
        var overlay: CIImage?

        if options.drawsClickRings,
           let ringImage = ringImage(at: time, center: CGPoint(x: pixelX, y: pixelY), size: cursorSize) {
            overlay = ringImage
        }
        if let cursorImage = arrowImage(center: CGPoint(x: pixelX, y: pixelY), size: cursorSize) {
            overlay = overlay.map { cursorImage.composited(over: $0) } ?? cursorImage
        }
        guard let overlay else { return image }
        return overlay.composited(over: image)
    }

    private func ringImage(at time: TimeInterval, center: CGPoint, size: Double) -> CIImage? {
        guard let click = clickTimes.last(where: { $0 <= time && time - $0 <= options.clickRingDuration })
        else { return nil }
        let progress = (time - click) / options.clickRingDuration
        let radius = size * (0.6 + 1.4 * progress)
        let alpha = 1 - progress
        return CursorRenderer.drawing(size: CGSize(width: radius * 2 + 8, height: radius * 2 + 8), origin: CGPoint(
            x: center.x - radius - 4,
            y: center.y - radius - 4
        )) { context in
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            context.setLineWidth(max(2, size * 0.08))
            context.strokeEllipse(in: CGRect(
                x: 4,
                y: 4,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }

    private func arrowImage(center: CGPoint, size: Double) -> CIImage? {
        let padding = size * 0.2
        let height = size + padding * 2
        // Places the tip exactly on the recorded cursor position.
        return arrow?.transformed(by: CGAffineTransform(
            translationX: center.x - padding,
            y: center.y - height + padding
        ))
    }

    private static func rasterizeArrow(size: Double) -> CIImage? {
        // Arrow outline in a unit box with the hotspot (the tip) at (0, 0) and
        // y growing downwards, the way a cursor is normally described.
        let points: [CGPoint] = [
            CGPoint(x: 0.00, y: 0.00), CGPoint(x: 0.00, y: 0.78), CGPoint(x: 0.22, y: 0.60),
            CGPoint(x: 0.36, y: 0.95), CGPoint(x: 0.52, y: 0.88), CGPoint(x: 0.38, y: 0.54),
            CGPoint(x: 0.64, y: 0.54)
        ]
        let padding = size * 0.2
        let height = size + padding * 2
        return drawing(
            size: CGSize(width: size + padding * 2, height: height),
            origin: .zero
        ) { context in
            context.setShadow(offset: CGSize(width: 0, height: -size * 0.05), blur: size * 0.12)
            let path = CGMutablePath()
            for (index, point) in points.enumerated() {
                let converted = CGPoint(
                    x: padding + point.x * size,
                    y: height - padding - point.y * size
                )
                if index == 0 { path.move(to: converted) } else { path.addLine(to: converted) }
            }
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.setLineWidth(max(1, size * 0.05))
            context.strokePath()
        }
    }

    private static func drawing(
        size: CGSize,
        origin: CGPoint,
        _ body: (CGContext) -> Void
    ) -> CIImage? {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        body(context)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}
#endif
