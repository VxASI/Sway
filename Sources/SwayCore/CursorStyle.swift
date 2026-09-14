import Foundation

/// How the recorded cursor is drawn back into the video. Because the capture
/// itself has no cursor in it, every one of these is a post-recording choice
/// that applies identically to preview and export.
public struct CursorStyle: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable, Identifiable {
        /// The pointer the user actually saw: arrow, I-beam, hand, resize...
        /// captured during recording. Falls back to `.arrow` when a recording
        /// predates shape capture.
        case recorded
        /// Sway's classic arrow: sharp, filled with the tint, contrasting outline.
        case arrow
        /// A softer, rounded pointer.
        case rounded
        /// A solid dot on the hotspot - unambiguous in tutorials.
        case dot
        /// The recorded pointer (or the arrow) inside a translucent tinted ring.
        case halo
        /// A PNG the user imported; see `customImage`.
        case custom

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .recorded: return "As recorded"
            case .arrow: return "Classic arrow"
            case .rounded: return "Rounded arrow"
            case .dot: return "Dot"
            case .halo: return "Halo"
            case .custom: return "Custom image…"
            }
        }

        /// Whether `tint` colors this shape.
        public var isTinted: Bool {
            switch self {
            case .arrow, .rounded, .dot, .halo: return true
            case .recorded, .custom: return false
            }
        }
    }

    /// Fill color for the drawn shapes; the outline is the contrasting one.
    public enum Tint: String, Codable, CaseIterable, Sendable, Identifiable {
        case white, black, blue, orange, purple, green

        public var id: String { rawValue }
        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        public var rgb: (Double, Double, Double) {
            switch self {
            case .white: return (1, 1, 1)
            case .black: return (0.08, 0.08, 0.09)
            case .blue: return (0.30, 0.56, 1.0)
            case .orange: return (1.0, 0.58, 0.22)
            case .purple: return (0.62, 0.40, 0.95)
            case .green: return (0.30, 0.82, 0.50)
            }
        }

        public var outline: (Double, Double, Double) {
            self == .black ? (1, 1, 1) : (0, 0, 0)
        }
    }

    /// How a recorded system pointer is colored. macOS pointers are black with
    /// a white edge; `.light` inverts that so they match Sway's white cursor.
    public enum RecordedColor: String, Codable, CaseIterable, Sendable, Identifiable {
        case light, dark
        public var id: String { rawValue }
        public var label: String { self == .light ? "Light" : "Dark (as shown)" }
    }

    /// An imported pointer image, stored in the bundle's `cursors/` directory,
    /// with its hotspot as a fraction of the image (0...1, top-left origin).
    public struct CustomImage: Codable, Hashable, Sendable {
        public var fileName: String
        public var hotspotX: Double
        public var hotspotY: Double
        /// Displayed width in points at 1x; height follows the image's aspect.
        public var pointWidth: Double

        public init(fileName: String, hotspotX: Double = 0, hotspotY: Double = 0, pointWidth: Double = 24) {
            self.fileName = fileName
            self.hotspotX = hotspotX
            self.hotspotY = hotspotY
            self.pointWidth = pointWidth
        }
    }

    public enum RingColor: String, Codable, CaseIterable, Sendable, Identifiable {
        case white, accent, warm

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .white: return "White"
            case .accent: return "Blue"
            case .warm: return "Orange"
            }
        }

        public var rgb: (Double, Double, Double) {
            switch self {
            case .white: return (1, 1, 1)
            case .accent: return (0.35, 0.60, 1.0)
            case .warm: return (1.0, 0.60, 0.25)
            }
        }
    }

    public var isVisible: Bool
    /// Multiplier on the macOS default cursor size.
    public var size: Double
    /// 0 = the raw recorded path, 1 = heavily smoothed motion.
    public var smoothing: Double
    public var shape: Shape
    public var tint: Tint
    public var recordedColor: RecordedColor
    public var customImage: CustomImage?
    public var clickRings: Bool
    public var ringColor: RingColor
    /// Dims everything except a soft circle around the cursor.
    public var spotlight: Bool
    /// Fade the cursor out after it has not moved for `idleSeconds`.
    public var hideWhenIdle: Bool
    public var idleSeconds: Double
    /// Fade the cursor out while keys are being pressed.
    public var hideWhileTyping: Bool

    public init(
        isVisible: Bool = true,
        size: Double = 1.4,
        smoothing: Double = 0.35,
        shape: Shape = .recorded,
        tint: Tint = .white,
        recordedColor: RecordedColor = .light,
        customImage: CustomImage? = nil,
        clickRings: Bool = true,
        ringColor: RingColor = .white,
        spotlight: Bool = false,
        hideWhenIdle: Bool = false,
        idleSeconds: Double = 2.0,
        hideWhileTyping: Bool = false
    ) {
        self.isVisible = isVisible
        self.size = size
        self.smoothing = smoothing
        self.shape = shape
        self.tint = tint
        self.recordedColor = recordedColor
        self.customImage = customImage
        self.clickRings = clickRings
        self.ringColor = ringColor
        self.spotlight = spotlight
        self.hideWhenIdle = hideWhenIdle
        self.idleSeconds = idleSeconds
        self.hideWhileTyping = hideWhileTyping
    }

    public static let standard = CursorStyle()

    private enum CodingKeys: String, CodingKey {
        case isVisible, size, smoothing, shape, tint, recordedColor, customImage, clickRings, ringColor
        case spotlight, hideWhenIdle, idleSeconds, hideWhileTyping
    }

    /// Tolerant decoding: every field falls back to its default, so an edit
    /// written by an older build still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorStyle.standard
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? d.isVisible
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? d.shape
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint) ?? d.tint
        recordedColor = try c.decodeIfPresent(RecordedColor.self, forKey: .recordedColor) ?? d.recordedColor
        customImage = try c.decodeIfPresent(CustomImage.self, forKey: .customImage)
        clickRings = try c.decodeIfPresent(Bool.self, forKey: .clickRings) ?? d.clickRings
        ringColor = try c.decodeIfPresent(RingColor.self, forKey: .ringColor) ?? d.ringColor
        spotlight = try c.decodeIfPresent(Bool.self, forKey: .spotlight) ?? d.spotlight
        hideWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? d.hideWhenIdle
        idleSeconds = try c.decodeIfPresent(Double.self, forKey: .idleSeconds) ?? d.idleSeconds
        hideWhileTyping = try c.decodeIfPresent(Bool.self, forKey: .hideWhileTyping) ?? d.hideWhileTyping
    }

    public func clamped() -> CursorStyle {
        var style = self
        style.size = clamp(style.size, 0.5, 3)
        style.smoothing = clamp(style.smoothing, 0, 1)
        style.idleSeconds = clamp(style.idleSeconds, 0.5, 10)
        if var custom = style.customImage {
            custom.hotspotX = clamp(custom.hotspotX, 0, 1)
            custom.hotspotY = clamp(custom.hotspotY, 0, 1)
            custom.pointWidth = clamp(custom.pointWidth, 8, 128)
            style.customImage = custom
        }
        return style
    }

    /// Time constant of the exponential smoothing applied to the drawn path.
    /// 0 keeps the raw path; 1 is a very floaty ~150 ms.
    public var smoothingTimeConstant: TimeInterval {
        smoothing <= 0 ? 0 : 0.02 + 0.13 * smoothing
    }
}

/// One system pointer image captured during recording, so the editor can draw
/// exactly what the user saw. Coordinates are in points at 1x; the renderer
/// scales by the capture's backing factor.
public struct CursorShape: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// PNG file name inside the bundle's `cursors/` directory.
    public var fileName: String
    public var width: Double
    public var height: Double
    public var hotspotX: Double
    public var hotspotY: Double

    public init(id: String, fileName: String, width: Double, height: Double, hotspotX: Double, hotspotY: Double) {
        self.id = id
        self.fileName = fileName
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
    }
}

/// When the pointer changed shape, in recording time.
public struct CursorShapeChange: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var shapeID: String

    public init(time: TimeInterval, shapeID: String) {
        self.time = time
        self.shapeID = shapeID
    }
}

/// The pointer-shape timeline: every distinct cursor image seen while
/// recording, and when the pointer switched between them.
public struct CursorShapeTrack: Codable, Equatable, Sendable {
    public var shapes: [CursorShape]
    public var changes: [CursorShapeChange]

    public init(shapes: [CursorShape] = [], changes: [CursorShapeChange] = []) {
        self.shapes = shapes
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }

    public func shape(at time: TimeInterval) -> CursorShape? {
        guard !changes.isEmpty else { return nil }
        var low = 0
        var high = changes.count - 1
        if time < changes[0].time { return shapes.first { $0.id == changes[0].shapeID } }
        while high - low > 1 {
            let mid = (low + high) / 2
            if changes[mid].time <= time { low = mid } else { high = mid }
        }
        let id = changes[high].time <= time ? changes[high].shapeID : changes[low].shapeID
        return shapes.first { $0.id == id }
    }

    /// Shifts every change so `offset` becomes time zero, dropping anything
    /// before it. Mirrors the rebase the cursor track gets after recording.
    public func rebased(by offset: TimeInterval) -> CursorShapeTrack {
        var shifted = changes.map { CursorShapeChange(time: $0.time - offset, shapeID: $0.shapeID) }
        // Keep the last change from before zero so the initial shape is known.
        if let lastBefore = shifted.lastIndex(where: { $0.time < 0 }) {
            var initial = shifted[lastBefore]
            initial.time = 0
            shifted = [initial] + shifted[(lastBefore + 1)...]
        }
        return CursorShapeTrack(shapes: shapes, changes: shifted)
    }
}
