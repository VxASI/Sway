#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import SwayCore

public enum ScreenRecordingError: Error, CustomStringConvertible {
    case noDisplayAvailable
    case displayNotFound(UInt32)
    case windowNotFound(UInt32)
    case writerSetupFailed(String)
    case notRecording

    public var description: String {
        switch self {
        case .noDisplayAvailable:
            return "No capturable display was returned by ScreenCaptureKit."
        case .displayNotFound(let id):
            return "Display \(id) is not available for capture."
        case .windowNotFound(let id):
            return "Window \(id) is not available for capture; it may have been closed."
        case .writerSetupFailed(let reason):
            return "Could not set up the movie writer: \(reason)"
        case .notRecording:
            return "The recorder is not running."
        }
    }
}

/// What the recorder points at: one whole display, or one window wherever it
/// happens to be.
public enum CaptureTarget: Sendable, Equatable {
    /// `nil` picks the main display.
    case display(UInt32?)
    case window(CGWindowID)

    public static let mainDisplay = CaptureTarget.display(nil)
}

public struct ScreenRecorderOptions: Sendable {
    public var target: CaptureTarget
    /// Region to capture, in global points (top-left origin). `nil` captures
    /// the whole display. Ignored for window capture; requires macOS 14.
    public var region: CGRect?
    public var frameRate: Int
    public var capturesSystemAudio: Bool
    /// Applications kept out of the capture, by bundle identifier. Sway passes
    /// its own identifier so the picker and the recording control never end up
    /// in the recording.
    public var excludedBundleIdentifiers: [String]
    /// Codec used for the screen track.
    public var codec: AVVideoCodecType

    public init(
        target: CaptureTarget = .mainDisplay,
        region: CGRect? = nil,
        frameRate: Int = 60,
        capturesSystemAudio: Bool = true,
        excludedBundleIdentifiers: [String] = [],
        codec: AVVideoCodecType = .h264
    ) {
        self.target = target
        self.region = region
        self.frameRate = frameRate
        self.capturesSystemAudio = capturesSystemAudio
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.codec = codec
    }
}

/// ScreenCaptureKit capture written straight to a QuickTime movie.
///
/// The system cursor is deliberately excluded (`showsCursor = false`): Sway
/// re-draws it at preview/export time from the recorded event stream, which is
/// what makes smoothing, click rings and typing auto-hide possible.
public final class ScreenRecorder: NSObject, @unchecked Sendable {
    public private(set) var geometry: CaptureGeometry?
    public private(set) var isRecording = false

    private let options: ScreenRecorderOptions
    private let bridge: HostClockBridge
    private let outputURL: URL

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private let stateQueue = DispatchQueue(label: "ai.sway.recorder.state")
    private let videoQueue = DispatchQueue(label: "ai.sway.recorder.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "ai.sway.recorder.audio", qos: .userInitiated)

    private var sessionStarted = false
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?

    public init(outputURL: URL, options: ScreenRecorderOptions, bridge: HostClockBridge) {
        self.outputURL = outputURL
        self.options = options
        self.bridge = bridge
        super.init()
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let filter: SCContentFilter
        let display: SCDisplay
        var captureRect: CGRect

        switch options.target {
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenRecordingError.windowNotFound(windowID)
            }
            display = try ScreenRecorder.display(containing: window.frame, in: content)
            captureRect = window.frame
            filter = SCContentFilter(desktopIndependentWindow: window)

        case .display(let displayID):
            if let displayID {
                guard let match = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw ScreenRecordingError.displayNotFound(displayID)
                }
                display = match
            } else {
                guard let main = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                    throw ScreenRecordingError.noDisplayAvailable
                }
                display = main
            }
            let displayBounds = CGDisplayBounds(display.displayID)
            captureRect = displayBounds
            if let region = options.region {
                let clipped = region.intersection(displayBounds)
                if !clipped.isNull && !clipped.isEmpty {
                    captureRect = clipped
                }
            }
            // Sway's own windows are dropped by the capture system itself, so
            // the picker and the recording control never appear in the frames.
            let excluded = content.applications.filter {
                options.excludedBundleIdentifiers.contains($0.bundleIdentifier)
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: excluded,
                exceptingWindows: []
            )
        }

        let displayBounds = CGDisplayBounds(display.displayID)
        let scale = Double(displayBounds.width) > 0
            ? Double(display.width) / Double(displayBounds.width)
            : 1
        // Keep pixel dimensions even; H.264 rejects odd dimensions.
        let pixelWidth = Int((Double(captureRect.width) * scale).rounded()) & ~1
        let pixelHeight = Int((Double(captureRect.height) * scale).rounded()) & ~1

        let configuration = SCStreamConfiguration()
        configuration.width = max(2, pixelWidth)
        configuration.height = max(2, pixelHeight)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = options.capturesSystemAudio
        if #available(macOS 14.0, *), options.region != nil, case .display = options.target {
            // sourceRect is display-local, with the display's own origin.
            configuration.sourceRect = CGRect(
                x: captureRect.origin.x - displayBounds.origin.x,
                y: captureRect.origin.y - displayBounds.origin.y,
                width: captureRect.width,
                height: captureRect.height
            )
        }

        let geometry = CaptureGeometry(
            displayID: display.displayID,
            x: Double(captureRect.origin.x),
            y: Double(captureRect.origin.y),
            width: Double(captureRect.width),
            height: Double(captureRect.height),
            pixelWidth: configuration.width,
            pixelHeight: configuration.height
        )
        self.geometry = geometry

        try setUpWriter(width: configuration.width, height: configuration.height)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if options.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        isRecording = true
    }

    /// The display a window sits on, so window captures inherit that display's
    /// backing scale.
    private static func display(containing frame: CGRect, in content: SCShareableContent) throws -> SCDisplay {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let match = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) {
            return match
        }
        guard let fallback = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else {
            throw ScreenRecordingError.noDisplayAvailable
        }
        return fallback
    }

    /// Stops the capture and finishes the movie. Returns the recorded duration
    /// in the shared timebase.
    @discardableResult
    public func stop() async throws -> TimeInterval {
        guard isRecording, let stream else { throw ScreenRecordingError.notRecording }
        isRecording = false
        try await stream.stopCapture()
        self.stream = nil

        let duration: TimeInterval = stateQueue.sync {
            guard let first = firstPresentationTime, let last = lastPresentationTime else { return 0 }
            return CMTimeGetSeconds(CMTimeSubtract(last, first))
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let writer {
            await writer.finishWriting()
            if writer.status == .failed, let error = writer.error {
                throw error
            }
        }
        return duration
    }

    /// Offset between the start of the movie and the start of the timebase.
    /// Cursor times are relative to the timebase; subtracting this offset lines
    /// them up with the video's own zero.
    public var videoStartOffset: TimeInterval {
        stateQueue.sync {
            guard let first = firstPresentationTime else { return 0 }
            return bridge.relativeTime(forPresentationTime: first)
        }
    }

    private func setUpWriter(width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, width * height * options.frameRate / 12),
                AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingError.writerSetupFailed("video input rejected")
        }
        writer.add(videoInput)
        self.videoInput = videoInput

        if options.capturesSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 192_000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            }
        }

        guard writer.startWriting() else {
            throw ScreenRecordingError.writerSetupFailed(writer.error?.localizedDescription ?? "unknown")
        }
        self.writer = writer
    }
}

extension ScreenRecorder: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer, writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch type {
        case .screen:
            guard isComplete(sampleBuffer) else { return }
            var shouldAppend = false
            stateQueue.sync {
                if !sessionStarted {
                    writer.startSession(atSourceTime: pts)
                    sessionStarted = true
                    firstPresentationTime = pts
                }
                lastPresentationTime = pts
                shouldAppend = true
            }
            if shouldAppend, let input = videoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        case .audio:
            let ready = stateQueue.sync { sessionStarted }
            guard ready, let input = audioInput, input.isReadyForMoreMediaData else { return }
            input.append(sampleBuffer)
        default:
            break
        }
    }

    /// ScreenCaptureKit also delivers idle/blank frames; only complete ones
    /// carry new pixels.
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw) else {
            return false
        }
        return status == .complete
    }
}
#endif
