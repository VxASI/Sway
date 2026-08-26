import Foundation

/// Kinds of pointer input Sway records alongside the screen video.
public enum CursorEventType: String, Codable, Sendable {
    case move
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case leftMouseDragged
    case rightMouseDragged
    case scrollWheel
    /// Periodic position verification, emitted even when no input happens.
    case sample

    public var isClickDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown
    }

    public var isDrag: Bool {
        self == .leftMouseDragged || self == .rightMouseDragged
    }
}

/// A single pointer observation expressed in the recording's shared timebase and
/// in coordinates normalized to the capture rect (origin top-left, 0...1).
public struct CursorEvent: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var x: Double
    public var y: Double
    public var type: CursorEventType
    /// Scroll deltas, only present for `.scrollWheel`.
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?

    public init(
        time: TimeInterval,
        x: Double,
        y: Double,
        type: CursorEventType,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil
    ) {
        self.time = time
        self.x = x
        self.y = y
        self.type = type
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }

    enum CodingKeys: String, CodingKey {
        case time, x, y, type
        case scrollDeltaX = "sdx"
        case scrollDeltaY = "sdy"
    }
}
