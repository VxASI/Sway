import Foundation

/// Metadata describing one recording, stored next to the media inside a
/// `.sway` bundle.
public struct SwayProject: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// User-editable display name. `nil` falls back to the bundle's file name.
    public var name: String?
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
        name: String? = nil,
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
        self.name = name
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
    public static let editFileName = "edit.json"
    public static let shapesFileName = "shapes.json"
    public static let cursorsDirectoryName = "cursors"
    public static let pathExtension = "sway"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var videoURL: URL { url.appendingPathComponent(SwayProjectBundle.videoFileName) }
    public var projectURL: URL { url.appendingPathComponent(SwayProjectBundle.projectFileName) }
    public var cursorURL: URL { url.appendingPathComponent(SwayProjectBundle.cursorFileName) }
    public var cameraURL: URL { url.appendingPathComponent(SwayProjectBundle.cameraFileName) }
    public var editURL: URL { url.appendingPathComponent(SwayProjectBundle.editFileName) }
    public var shapesURL: URL { url.appendingPathComponent(SwayProjectBundle.shapesFileName) }
    public var cursorsDirectoryURL: URL {
        url.appendingPathComponent(SwayProjectBundle.cursorsDirectoryName, isDirectory: true)
    }

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

    public func write(edit: SwayEdit) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(edit).write(to: editURL, options: .atomic)
    }

    public func readEdit() throws -> SwayEdit {
        try JSONDecoder().decode(SwayEdit.self, from: Data(contentsOf: editURL))
    }

    public func write(project: SwayProject) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: projectURL, options: .atomic)
    }

    public func write(shapes: CursorShapeTrack) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(shapes).write(to: shapesURL, options: .atomic)
    }

    /// Empty for bundles recorded before pointer shapes were captured.
    public func readShapes() -> CursorShapeTrack {
        guard let data = try? Data(contentsOf: shapesURL),
              let shapes = try? JSONDecoder().decode(CursorShapeTrack.self, from: data) else {
            return CursorShapeTrack()
        }
        return shapes
    }

    public func write(camera: CameraPath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(camera).write(to: cameraURL, options: .atomic)
    }
}
