#if os(macOS)
import AVFoundation
import CoreImage
import XCTest
@testable import SwayCapture
@testable import SwayCore

/// End-to-end exporter tests against a synthesized `.sway` bundle: a real
/// H.264 movie with an audio track, a moving cursor track, and a camera path
/// generated from effect segments. These are the same code paths the app's
/// export button runs.
final class CinematicExporterTests: XCTestCase {
    private var bundleURL: URL!
    private var bundle: SwayProjectBundle!
    private let duration: TimeInterval = 4
    private let size = CGSize(width: 640, height: 360)

    override func setUp() async throws {
        bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporter-tests-\(UUID().uuidString).sway")
        bundle = SwayProjectBundle(url: bundleURL)
        try bundle.createDirectory()
        try await writeTestMovie(to: bundle.videoURL)

        var events: [CursorEvent] = []
        var t: TimeInterval = 0
        while t <= duration {
            let progress = t / duration
            events.append(CursorEvent(time: t, x: 0.2 + 0.6 * progress, y: 0.5, type: .move))
            t += 1.0 / 30
        }
        events.append(CursorEvent(time: 2, x: 0.5, y: 0.5, type: .leftMouseDown))
        let track = CursorTrack(events: events.sorted { $0.time < $1.time })

        let geometry = CaptureGeometry(
            displayID: 1, x: 0, y: 0,
            width: Double(size.width), height: Double(size.height),
            pixelWidth: Int(size.width), pixelHeight: Int(size.height)
        )
        let project = SwayProject(
            duration: duration,
            geometry: geometry,
            hasSystemAudio: true,
            hasMicrophoneAudio: false,
            startHostSeconds: 0
        )
        try bundle.write(project: project, track: track, camera: nil)
    }

    override func tearDown() {
        if let bundleURL {
            try? FileManager.default.removeItem(at: bundleURL)
        }
    }

    func testExportBakesSegmentsAndReportsProgress() async throws {
        let track = try bundle.readCursorTrack()
        let segments = EffectSegment.resolved([
            EffectSegment(kind: .zoom, start: 0.5, end: 1.8, zoom: 2, centerX: 0.7, centerY: 0.5),
            EffectSegment(kind: .followCursor, start: 2, end: 3.5, zoom: 2)
        ], duration: duration)
        let camera = CameraPathGenerator().generate(track: track, duration: duration, segments: segments)

        let output = bundleURL.deletingPathExtension().appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let progressValues = ProgressCollector()
        let exporter = CinematicExporter(bundle: bundle, options: ExportOptions(), camera: camera)
        try await exporter.export(to: output) { progressValues.record($0) }

        let asset = AVURLAsset(url: output)
        let exportedDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(exportedDuration, duration, accuracy: 0.35)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "audio should survive the export")

        let recorded = progressValues.values
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertEqual(recorded.last ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(recorded, recorded.sorted(), "progress must be monotonic")
    }

    func testTrimmedExportKeepsAudioAndShortens() async throws {
        let output = bundleURL.deletingPathExtension().appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = CinematicExporter(
            bundle: bundle,
            options: ExportOptions(trim: 1.0...3.0)
        )
        try await exporter.export(to: output)

        let asset = AVURLAsset(url: output)
        let exportedDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(exportedDuration, 2.0, accuracy: 0.35)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "trimmed exports keep their audio now")
    }

    func testAspectPresetExportsExactDimensionsWithoutStretching() async throws {
        let output = bundleURL.deletingPathExtension().appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = CinematicExporter(
            bundle: bundle,
            options: ExportOptions(size: CGSize(width: 270, height: 480))
        )
        try await exporter.export(to: output)

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let naturalSize = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(naturalSize.width, 270)
        XCTAssertEqual(naturalSize.height, 480)
    }

    func testFrameRateCapReducesFrameCount() async throws {
        let full = bundleURL.deletingPathExtension().appendingPathExtension("full.mp4")
        let capped = bundleURL.deletingPathExtension().appendingPathExtension("capped.mp4")
        defer {
            try? FileManager.default.removeItem(at: full)
            try? FileManager.default.removeItem(at: capped)
        }

        try await CinematicExporter(bundle: bundle, options: ExportOptions()).export(to: full)
        try await CinematicExporter(
            bundle: bundle,
            options: ExportOptions(frameRate: 15)
        ).export(to: capped)

        let cappedCount = try await frameCount(of: capped)
        let fullCount = try await frameCount(of: full)
        XCTAssertEqual(cappedCount, 60, "four seconds at 15 fps has no extra boundary frame")
        XCTAssertEqual(fullCount, 240, "four seconds at 60 fps has no extra boundary frame")
    }

    func testInvalidOptionsPreserveExistingExport() async throws {
        let output = bundleURL.appendingPathExtension("mp4")
        let original = Data("previous export".utf8)
        try original.write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }

        let invalidOptions = [
            ExportOptions(frameRate: 0),
            ExportOptions(frameRate: -1),
            ExportOptions(frameRate: 241),
            ExportOptions(trim: 2...2),
            ExportOptions(trim: -1...2),
            ExportOptions(trim: 0...5),
            ExportOptions(size: CGSize(width: CGFloat.infinity, height: 360)),
            ExportOptions(size: CGSize(width: 640.5, height: 360)),
            ExportOptions(averageBitRate: 0)
        ]
        for options in invalidOptions {
            do {
                try await CinematicExporter(bundle: bundle, options: options).export(to: output)
                XCTFail("Invalid options should fail before rendering")
            } catch ExportError.invalidOptions {
                // Expected: a useful error, without touching the destination.
            }
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
    }

    func testExportCannotOverwriteSourceBundleOrFilesThroughSymlink() async throws {
        let original = try Data(contentsOf: bundle.videoURL)
        let alias = bundleURL.appendingPathExtension("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundleURL)
        defer { try? FileManager.default.removeItem(at: alias) }

        for output in [bundleURL!, bundle.videoURL, bundle.projectURL,
                       alias.appendingPathComponent(SwayProjectBundle.videoFileName)] {
            do {
                try await CinematicExporter(bundle: bundle).export(to: output)
                XCTFail("Export must not replace its own source")
            } catch ExportError.invalidDestination {
                // Expected, even for aliases into the source bundle.
            }
        }
        XCTAssertEqual(try Data(contentsOf: bundle.videoURL), original)
        XCTAssertEqual(try bundle.readProject().duration, duration)
    }

    func testSuccessfulExportReplacesExistingDestinationAndCleansStagingFile() async throws {
        let directory = bundleURL.appendingPathExtension("exports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("finished.mp4")
        try Data("old movie".utf8).write(to: output)

        try await CinematicExporter(bundle: bundle, options: ExportOptions(frameRate: 15))
            .export(to: output)

        let count = try await frameCount(of: output)
        XCTAssertEqual(count, 60)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["finished.mp4"])
    }

    func testNonFrameAlignedTrimHasExactFrameCount() async throws {
        let output = bundleURL.appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await CinematicExporter(
            bundle: bundle, options: ExportOptions(trim: 0.11...1.12, frameRate: 30)
        ).export(to: output)
        let count = try await frameCount(of: output)
        XCTAssertEqual(count, 31)
        let exportedDuration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(exportedDuration, 1.01, accuracy: 0.02)
    }

    // MARK: - Helpers

    private func frameCount(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        return count
    }

    /// A 30 fps H.264 movie with moving content and a silent stereo audio
    /// track - shaped like a real `screen.mov`, timeline starting at zero.
    private func writeTestMovie(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        // Real-time mode keeps `isReadyForMoreMediaData` usable from a plain
        // loop; without it the flag only flips via requestMediaDataWhenReady.
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(videoInput)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ])
        audioInput.expectsMediaDataInRealTime = true
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        let fps = 30
        for frame in 0..<Int(duration * Double(fps)) {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault, adaptor.pixelBufferPool!, &pixelBuffer
            )
            guard let pixelBuffer else { continue }
            let hue = Double(frame % fps) / Double(fps)
            let image = CIImage(color: CIColor(red: hue, green: 0.4, blue: 1 - hue))
                .cropped(to: CGRect(origin: .zero, size: size))
            context.render(image, to: pixelBuffer)
            adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            )
        }
        videoInput.markAsFinished()

        for chunk in 0..<Int(duration) {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if let sample = CinematicExporterTests.silentAudioSample(
                startTime: Double(chunk), duration: 1, sampleRate: 44_100
            ) {
                audioInput.append(sample)
            }
        }
        audioInput.markAsFinished()

        await writer.finishWriting()
        if writer.status == .failed, let error = writer.error {
            throw error
        }
    }

    private static func silentAudioSample(
        startTime: TimeInterval,
        duration: TimeInterval,
        sampleRate: Double
    ) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard let format else { return nil }

        let frames = Int(sampleRate * duration)
        let byteCount = frames * 4
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { return nil }
        CMBlockBufferFillDataBytes(
            with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount
        )

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: startTime, preferredTimescale: 44_100),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        return sample
    }
}

/// Progress callbacks arrive on the export queue; collect them thread-safely.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
#endif
