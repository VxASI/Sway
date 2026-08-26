import Foundation

/// Metadata describing one recording, stored next to the media inside a
/// `.sway` bundle.
public struct SwayProject: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Wall-clock creation date. Informational only - never used for
    /// synchronization.
    public var createdAt: Date
    public var duration: TimeInterval
    public var geometry: CaptureGeometry
    public var videoFileName: String
    public var cursorTrackFileName: String
    public var cameraPathFileName: String?
    public var hasSystemAudio: Bool
    public var hasMicrophoneAudio: Bool
    /// Host-clock reading at recording start, kept for debugging drift.
    public var startHostSeconds: Double

    public init(
        version: Int = SwayProject.currentVersion,
        createdAt: Date = Date(),
        duration: TimeInterval,
        geometry: CaptureGeometry,
        videoFileName: String = SwayProjectBundle.videoFileName,
        cursorTrackFileName: String = SwayProjectBundle.cursorFileName,
        cameraPathFileName: String? = SwayProjectBundle.cameraFileName,
        hasSystemAudio: Bool,
        hasMicrophoneAudio: Bool,
        startHostSeconds: Double
    ) {
        self.version = version
        self.createdAt = createdAt
        self.duration = duration
        self.geometry = geometry
        self.videoFileName = videoFileName
        self.cursorTrackFileName = cursorTrackFileName
        self.cameraPathFileName = cameraPathFileName
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophoneAudio = hasMicrophoneAudio
        self.startHostSeconds = startHostSeconds
    }
}

/// Reads and writes the on-disk recording bundle:
///
/// ```
/// MyRecording.sway/
///   project.json   metadata, capture geometry, timebase
///   screen.mov     video (+ audio) with no baked-in cursor
///   cursor.json    cursor track in normalized capture coordinates
///   camera.json    generated camera path
/// ```
public struct SwayProjectBundle {
    public static let projectFileName = "project.json"
    public static let videoFileName = "screen.mov"
    public static let cursorFileName = "cursor.json"
    public static let cameraFileName = "camera.json"
    public static let pathExtension = "sway"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var videoURL: URL { url.appendingPathComponent(SwayProjectBundle.videoFileName) }
    public var projectURL: URL { url.appendingPathComponent(SwayProjectBundle.projectFileName) }
    public var cursorURL: URL { url.appendingPathComponent(SwayProjectBundle.cursorFileName) }
    public var cameraURL: URL { url.appendingPathComponent(SwayProjectBundle.cameraFileName) }

    @discardableResult
    public func createDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func write(project: SwayProject, track: CursorTrack, camera: CameraPath?) throws {
        try createDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: projectURL, options: .atomic)
        try encoder.encode(track).write(to: cursorURL, options: .atomic)
        if let camera {
            try encoder.encode(camera).write(to: cameraURL, options: .atomic)
        }
    }

    public func readProject() throws -> SwayProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SwayProject.self, from: Data(contentsOf: projectURL))
    }

    public func readCursorTrack() throws -> CursorTrack {
        try JSONDecoder().decode(CursorTrack.self, from: Data(contentsOf: cursorURL))
    }

    public func readCameraPath() throws -> CameraPath {
        try JSONDecoder().decode(CameraPath.self, from: Data(contentsOf: cameraURL))
    }
}
