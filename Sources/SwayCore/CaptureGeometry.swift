import Foundation

/// Everything needed to turn a global cursor location into a coordinate that is
/// meaningful inside the recorded video, and to interpret that coordinate again
/// at export time.
///
/// `rect` lives in CoreGraphics global display space: points, origin in the
/// top-left of the main display, y growing downwards. That is the space
/// `CGEvent.location` and `CGDisplayBounds` already use, and it matches the
/// video's orientation, so no vertical flip is needed anywhere in the pipeline.
public struct CaptureGeometry: Codable, Equatable, Sendable {
    public var displayID: UInt32
    /// Captured area in global points, top-left origin.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Video dimensions in pixels (width / `width` gives the backing scale).
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        displayID: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.displayID = displayID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var scale: Double {
        width > 0 ? Double(pixelWidth) / width : 1
    }

    public var aspectRatio: Double {
        pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1
    }

    /// Converts a global point into capture-relative normalized coordinates.
    /// Values outside 0...1 mean the cursor left the captured area; they are
    /// kept as-is so the camera engine can decide what to do about it.
    public func normalize(globalX: Double, globalY: Double) -> (x: Double, y: Double) {
        guard width > 0, height > 0 else { return (0, 0) }
        return ((globalX - x) / width, (globalY - y) / height)
    }

    /// Inverse of `normalize`, useful when drawing the cursor at export time.
    public func denormalize(x normalizedX: Double, y normalizedY: Double) -> (x: Double, y: Double) {
        (x + normalizedX * width, y + normalizedY * height)
    }

    public func contains(normalizedX: Double, normalizedY: Double) -> Bool {
        (0...1).contains(normalizedX) && (0...1).contains(normalizedY)
    }
}
