#if os(macOS)
import AVFoundation
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
    /// Output size in pixels. `nil` keeps the recorded size.
    public var size: CGSize?
    public var drawsCursor: Bool
    /// Cursor size relative to the recorded scale (1 = macOS default size).
    public var cursorScale: Double
    public var drawsClickRings: Bool
    public var clickRingDuration: TimeInterval
    public var codec: AVVideoCodecType

    public init(
        size: CGSize? = nil,
        drawsCursor: Bool = true,
        cursorScale: Double = 1.4,
        drawsClickRings: Bool = true,
        clickRingDuration: TimeInterval = 0.45,
        codec: AVVideoCodecType = .h264
    ) {
        self.size = size
        self.drawsCursor = drawsCursor
        self.cursorScale = cursorScale
        self.drawsClickRings = drawsClickRings
        self.clickRingDuration = clickRingDuration
        self.codec = codec
    }
}

/// Renders a `.sway` bundle into a finished movie: the camera path becomes a
/// moving crop of the source frames, and the cursor is drawn back in from the
/// recorded event stream (the capture itself has no cursor baked in).
public final class CinematicExporter {
    private let bundle: SwayProjectBundle
    private let options: ExportOptions
    private let context = CIContext()

    public init(bundle: SwayProjectBundle, options: ExportOptions = ExportOptions()) {
        self.bundle = bundle
        self.options = options
    }

    public func export(to outputURL: URL) async throws {
        let project = try bundle.readProject()
        let track = try bundle.readCursorTrack()
        let camera = (try? bundle.readCameraPath())
            ?? CameraPathGenerator().generate(track: track, duration: project.duration)

        let asset = AVURLAsset(url: bundle.videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let sourceSize = try await videoTrack.load(.naturalSize)
        let outputSize = options.size ?? sourceSize

        let reader = try AVAssetReader(asset: asset)
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
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: options.codec,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height)
            ]
        )
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
        var firstPTS: CMTime?

        let videoQueue = DispatchQueue(label: "ai.sway.export.video")
        var videoFinished = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    guard !videoFinished else { return }
                    guard let sample = videoOutput.copyNextSampleBuffer(),
                          let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        videoFinished = true
                        videoInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    if firstPTS == nil { firstPTS = pts }
                    let relative = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS ?? .zero))
                    let state = camera.state(at: relative)
                        ?? CameraKeyframe(time: relative, centerX: 0.5, centerY: 0.5, zoom: 1)

                    guard let rendered = self.renderFrame(
                        pixelBuffer: pixelBuffer,
                        camera: state,
                        time: relative,
                        outputSize: outputSize,
                        renderer: renderer,
                        pool: adaptor.pixelBufferPool
                    ) else { continue }
                    adaptor.append(rendered, withPresentationTime: CMTimeSubtract(pts, firstPTS ?? .zero))
                }
            }
        }

        if let audioInput, let audioOutput {
            let audioQueue = DispatchQueue(label: "ai.sway.export.audio")
            var audioFinished = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard !audioFinished else { return }
                        guard let sample = audioOutput.copyNextSampleBuffer() else {
                            audioFinished = true
                            audioInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                        audioInput.append(sample)
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status == .failed, let error = writer.error {
            throw error
        }
    }

    private func renderFrame(
        pixelBuffer: CVPixelBuffer,
        camera: CameraKeyframe,
        time: TimeInterval,
        outputSize: CGSize,
        renderer: CursorRenderer,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceWidth = source.extent.width
        let sourceHeight = source.extent.height

        // Camera coordinates are top-left origin; CoreImage is bottom-left.
        let cropWidth = sourceWidth / camera.zoom
        let cropHeight = sourceHeight / camera.zoom
        let cropX = camera.centerX * sourceWidth - cropWidth / 2
        let cropY = (1 - camera.centerY) * sourceHeight - cropHeight / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
            .intersection(source.extent)

        var image = source.cropped(to: cropRect)
        image = renderer.draw(on: image, fullExtent: source.extent, time: time).cropped(to: cropRect)
        image = image
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(
                scaleX: outputSize.width / cropRect.width,
                y: outputSize.height / cropRect.height
            ))

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
struct CursorRenderer {
    let options: ExportOptions
    let track: CursorTrack
    let scale: Double
    private let clickTimes: [TimeInterval]

    init(options: ExportOptions, track: CursorTrack, scale: Double) {
        self.options = options
        self.track = track
        self.scale = scale
        self.clickTimes = track.events.filter { $0.type.isClickDown }.map(\.time)
    }

    /// Cursor coordinates are normalized to the whole capture, so the overlay
    /// is placed in full-frame pixel space and the caller crops afterwards.
    func draw(on image: CIImage, fullExtent: CGRect, time: TimeInterval) -> CIImage {
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
        return drawing(size: CGSize(width: radius * 2 + 8, height: radius * 2 + 8), origin: CGPoint(
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
            // Places the tip exactly on the recorded cursor position.
            origin: CGPoint(x: center.x - padding, y: center.y - height + padding)
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

    private func drawing(
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
