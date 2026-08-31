import Foundation

/// A user-authored camera-mode boundary: the stretch of the recording that is
/// played back zoomed in and following the cursor.
///
/// Unlike `FocusSegment`, which is derived from clicks, a range is edited
/// directly on the timeline. The cursor track only decides where the camera
/// looks while the range is active; it never decides when the range starts or
/// ends.
public struct FocusRange: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// Zoom held inside the range (1 = full frame).
    public var zoom: Double

    public init(start: TimeInterval, end: TimeInterval, zoom: Double = 2.0) {
        self.start = start
        self.end = end
        self.zoom = zoom
    }

    public var duration: TimeInterval { max(0, end - start) }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }

    /// Keeps the range inside the recording and at least `minimumDuration`
    /// long, moving whichever edge was not being dragged.
    public func clamped(
        to duration: TimeInterval,
        minimumDuration: TimeInterval = 0.25,
        movingEnd: Bool = true
    ) -> FocusRange {
        var range = self
        range.start = clamp(range.start, 0, max(0, duration))
        range.end = clamp(range.end, 0, max(0, duration))
        if range.end - range.start < minimumDuration {
            if movingEnd {
                range.end = min(duration, range.start + minimumDuration)
                range.start = max(0, range.end - minimumDuration)
            } else {
                range.start = max(0, range.end - minimumDuration)
                range.end = min(duration, range.start + minimumDuration)
            }
        }
        range.zoom = clamp(range.zoom, 1, 6)
        return range
    }
}

/// Everything the editor lets the user change about a recording. Stored next to
/// the media so reopening a bundle restores the edit.
public struct SwayEdit: Codable, Equatable, Sendable {
    public var trimStart: TimeInterval
    public var trimEnd: TimeInterval
    /// User-authored effect segments, sorted and non-overlapping. Empty means
    /// the whole recording plays at 1x.
    public var segments: [EffectSegment]

    public init(trimStart: TimeInterval = 0, trimEnd: TimeInterval, segments: [EffectSegment] = []) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.segments = segments
    }

    public var trimmedDuration: TimeInterval { max(0, trimEnd - trimStart) }

    /// The single focus range of the first editor, kept so old `edit.json`
    /// files decode into an equivalent follow-cursor segment.
    private enum CodingKeys: String, CodingKey {
        case trimStart, trimEnd, segments, focus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try container.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? 0
        trimEnd = try container.decode(TimeInterval.self, forKey: .trimEnd)
        if let segments = try container.decodeIfPresent([EffectSegment].self, forKey: .segments) {
            self.segments = segments
        } else if let focus = try container.decodeIfPresent(FocusRange.self, forKey: .focus) {
            segments = [EffectSegment(
                kind: .followCursor,
                start: focus.start,
                end: focus.end,
                zoom: focus.zoom
            )]
        } else {
            segments = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trimStart, forKey: .trimStart)
        try container.encode(trimEnd, forKey: .trimEnd)
        try container.encode(segments, forKey: .segments)
    }

    /// The edit a freshly recorded bundle opens with: no trim, and a
    /// follow-cursor segment proposed from the detected interactions so the
    /// user has something to drag instead of a blank timeline.
    public static func initial(
        duration: TimeInterval,
        track: CursorTrack,
        detector: FocusDetector = FocusDetector()
    ) -> SwayEdit {
        var edit = SwayEdit(trimStart: 0, trimEnd: duration)
        guard duration > 0 else { return edit }
        let suggestion = detector.segments(for: track, duration: duration)
            .max(by: { $0.interactionCount < $1.interactionCount })
        let proposed: EffectSegment
        if let suggestion {
            proposed = EffectSegment(kind: .followCursor, start: suggestion.start, end: suggestion.end)
        } else {
            let start = duration * 0.25
            let end = min(duration, start + max(1.5, duration * 0.5))
            proposed = EffectSegment(kind: .followCursor, start: start, end: end)
        }
        edit.segments = EffectSegment.resolved([proposed], duration: duration)
        return edit
    }
}
