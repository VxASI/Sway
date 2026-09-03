import Foundation

/// What a timeline effect segment does to the virtual camera.
public enum EffectKind: String, Codable, Sendable, CaseIterable {
    /// Zoom into a fixed focal area chosen by the user.
    case zoom
    /// Zoom in and follow the recorded cursor.
    case followCursor
}

/// One user-authored stretch of camera behavior on the timeline. Outside all
/// segments the recording plays at 1x, dead center; segments never overlap.
///
/// This replaces the single `FocusRange` of the first editor. A `.zoom`
/// segment holds a fixed focal point; a `.followCursor` segment lets the
/// camera track the recorded cursor with a per-segment smoothing amount.
public struct EffectSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: EffectKind
    public var start: TimeInterval
    public var end: TimeInterval
    /// Zoom held inside the segment (1 = full frame).
    public var zoom: Double
    /// Focal point for `.zoom`, normalized to the capture (0...1).
    public var centerX: Double
    public var centerY: Double
    /// Camera easing for `.followCursor`: 0 = responsive, 1 = very smooth.
    public var smoothing: Double

    public init(
        id: UUID = UUID(),
        kind: EffectKind,
        start: TimeInterval,
        end: TimeInterval,
        zoom: Double = 2.0,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        smoothing: Double = 0.5
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
        self.smoothing = smoothing
    }

    public var duration: TimeInterval { max(0, end - start) }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }

    /// Keeps the segment inside the recording and at least `minimumDuration`
    /// long, moving whichever edge was not being dragged.
    public func clamped(
        to duration: TimeInterval,
        minimumDuration: TimeInterval = 0.25,
        movingEnd: Bool = true
    ) -> EffectSegment {
        var segment = self
        segment.start = clamp(segment.start, 0, max(0, duration))
        segment.end = clamp(segment.end, 0, max(0, duration))
        if segment.end - segment.start < minimumDuration {
            if movingEnd {
                segment.end = min(duration, segment.start + minimumDuration)
                segment.start = max(0, segment.end - minimumDuration)
            } else {
                segment.start = max(0, segment.end - minimumDuration)
                segment.end = min(duration, segment.start + minimumDuration)
            }
        }
        segment.zoom = clamp(segment.zoom, 1, 6)
        segment.centerX = clamp(segment.centerX, 0, 1)
        segment.centerY = clamp(segment.centerY, 0, 1)
        segment.smoothing = clamp(segment.smoothing, 0, 1)
        return segment
    }

    /// Sorts segments by start time and removes overlaps, trimming the later
    /// segment against the earlier one and dropping any that collapse below
    /// `minimumDuration`. The camera generator and timeline both assume this
    /// invariant.
    public static func resolved(
        _ segments: [EffectSegment],
        duration: TimeInterval,
        minimumDuration: TimeInterval = 0.25
    ) -> [EffectSegment] {
        var result: [EffectSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            var clamped = segment.clamped(to: duration, minimumDuration: minimumDuration)
            if let previous = result.last, clamped.start < previous.end {
                clamped.start = previous.end
            }
            guard clamped.end - clamped.start >= minimumDuration - 1e-9 else { continue }
            result.append(clamped)
        }
        return result
    }
}
