import Foundation

/// A stretch of the recording the camera should stay zoomed in on, anchored at
/// the centroid of the interactions that created it.
public struct FocusSegment: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var anchorX: Double
    public var anchorY: Double
    public var interactionCount: Int

    public init(
        start: TimeInterval,
        end: TimeInterval,
        anchorX: Double,
        anchorY: Double,
        interactionCount: Int
    ) {
        self.start = start
        self.end = end
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.interactionCount = interactionCount
    }

    public var duration: TimeInterval { end - start }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }
}

public struct FocusDetectorConfig: Sendable {
    /// Interactions closer together than this in time can share one shot.
    public var groupTimeWindow: TimeInterval
    /// ...as long as they are also this close together on screen (normalized).
    public var groupRadius: Double
    /// How early the camera starts moving in, before the first interaction.
    public var leadIn: TimeInterval
    /// How long the camera stays in after the last interaction of a group.
    public var zoomOutDelay: TimeInterval
    /// A focused shot never lasts less than this, to avoid a zoom in/out blink.
    public var minimumDuration: TimeInterval
    /// Segments separated by less than this are merged into one shot.
    public var mergeGap: TimeInterval

    public init(
        groupTimeWindow: TimeInterval = 2.0,
        groupRadius: Double = 0.18,
        leadIn: TimeInterval = 0.35,
        zoomOutDelay: TimeInterval = 1.2,
        minimumDuration: TimeInterval = 1.5,
        mergeGap: TimeInterval = 0.75
    ) {
        self.groupTimeWindow = groupTimeWindow
        self.groupRadius = groupRadius
        self.leadIn = leadIn
        self.zoomOutDelay = zoomOutDelay
        self.minimumDuration = minimumDuration
        self.mergeGap = mergeGap
    }
}

/// Turns discrete interactions (clicks, drags, scrolls) into focus segments.
///
/// Three clicks on nearby controls within a couple of seconds produce a single
/// segment, so the camera holds one shot instead of pumping in and out.
public struct FocusDetector: Sendable {
    public var config: FocusDetectorConfig

    public init(config: FocusDetectorConfig = FocusDetectorConfig()) {
        self.config = config
    }

    public func segments(for track: CursorTrack, duration: TimeInterval) -> [FocusSegment] {
        let interactions = track.events.filter { event in
            event.type.isClickDown || event.type.isDrag || event.type == .scrollWheel
        }
        guard !interactions.isEmpty else { return [] }

        var groups: [[CursorEvent]] = []
        var current: [CursorEvent] = [interactions[0]]
        for event in interactions.dropFirst() {
            let previous = current[current.count - 1]
            let dt = event.time - previous.time
            let distance = hypot(event.x - previous.x, event.y - previous.y)
            if dt <= config.groupTimeWindow && distance <= config.groupRadius {
                current.append(event)
            } else {
                groups.append(current)
                current = [event]
            }
        }
        groups.append(current)

        var segments = groups.map { group -> FocusSegment in
            let anchorX = group.reduce(0) { $0 + $1.x } / Double(group.count)
            let anchorY = group.reduce(0) { $0 + $1.y } / Double(group.count)
            var start = max(0, (group.first?.time ?? 0) - config.leadIn)
            var end = min(duration, (group.last?.time ?? 0) + config.zoomOutDelay)
            if end - start < config.minimumDuration {
                let deficit = config.minimumDuration - (end - start)
                end = min(duration, end + deficit)
                if end - start < config.minimumDuration {
                    start = max(0, end - config.minimumDuration)
                }
            }
            return FocusSegment(
                start: start,
                end: end,
                anchorX: anchorX,
                anchorY: anchorY,
                interactionCount: group.count
            )
        }

        // Merge shots that would otherwise be separated by a barely visible
        // zoom-out.
        var merged: [FocusSegment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            guard var last = merged.last else {
                merged.append(segment)
                continue
            }
            let anchorDistance = hypot(segment.anchorX - last.anchorX, segment.anchorY - last.anchorY)
            if segment.start - last.end <= config.mergeGap, anchorDistance <= config.groupRadius * 1.5 {
                let total = last.interactionCount + segment.interactionCount
                let weightA = Double(last.interactionCount) / Double(total)
                let weightB = Double(segment.interactionCount) / Double(total)
                last.end = max(last.end, segment.end)
                last.anchorX = last.anchorX * weightA + segment.anchorX * weightB
                last.anchorY = last.anchorY * weightA + segment.anchorY * weightB
                last.interactionCount = total
                merged[merged.count - 1] = last
            } else {
                // Two distinct shots: the later one starts where the earlier
                // one ends so the camera pans instead of cross-cutting.
                var next = segment
                next.start = max(next.start, last.end)
                next.end = max(next.end, next.start)
                merged.append(next)
            }
        }
        segments = merged
        return segments
    }
}
