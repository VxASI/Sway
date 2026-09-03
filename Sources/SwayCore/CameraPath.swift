import Foundation

/// One camera state, in the same normalized capture space as the cursor track.
/// `zoom` is a scale factor: the visible viewport is `1 / zoom` of the capture
/// on each axis, centered on (`centerX`, `centerY`).
public struct CameraKeyframe: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double

    public init(time: TimeInterval, centerX: Double, centerY: Double, zoom: Double) {
        self.time = time
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
    }
}

public struct CameraPath: Codable, Equatable, Sendable {
    public var frameRate: Double
    public var keyframes: [CameraKeyframe]

    public init(frameRate: Double, keyframes: [CameraKeyframe]) {
        self.frameRate = frameRate
        self.keyframes = keyframes
    }

    /// Camera state at an arbitrary time, interpolated between keyframes, so
    /// the renderer is not tied to the path's own frame rate.
    public func state(at time: TimeInterval) -> CameraKeyframe? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        if time <= first.time { return first }
        if time >= last.time { return last }

        var low = 0
        var high = keyframes.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if keyframes[mid].time <= time { low = mid } else { high = mid }
        }
        let a = keyframes[low]
        let b = keyframes[high]
        let span = b.time - a.time
        guard span > 0 else { return b }
        let t = (time - a.time) / span
        return CameraKeyframe(
            time: time,
            centerX: a.centerX + (b.centerX - a.centerX) * t,
            centerY: a.centerY + (b.centerY - a.centerY) * t,
            zoom: a.zoom + (b.zoom - a.zoom) * t
        )
    }
}

public struct CameraConfig: Sendable {
    /// Camera path resolution. Independent of the video frame rate; the
    /// renderer interpolates between keyframes.
    public var frameRate: Double
    /// Zoom used inside a focus segment.
    public var focusZoom: Double
    /// Zoom outside focus segments (1 = full frame).
    public var restZoom: Double
    /// The cursor may roam this far (normalized, in viewport units) from the
    /// camera center before the camera starts following it.
    public var deadZone: Double
    /// Seconds of cursor velocity to lead by, so the camera arrives with the
    /// cursor instead of trailing it.
    public var lookAhead: TimeInterval
    /// Cap on the look-ahead offset, in normalized units.
    public var maxLookAhead: Double
    public var centerStiffness: Double
    public var zoomStiffness: Double

    public init(
        frameRate: Double = 60,
        focusZoom: Double = 1.8,
        restZoom: Double = 1.0,
        deadZone: Double = 0.18,
        lookAhead: TimeInterval = 0.18,
        maxLookAhead: Double = 0.12,
        centerStiffness: Double = 45,
        zoomStiffness: Double = 22
    ) {
        self.frameRate = frameRate
        self.focusZoom = focusZoom
        self.restZoom = restZoom
        self.deadZone = deadZone
        self.lookAhead = lookAhead
        self.maxLookAhead = maxLookAhead
        self.centerStiffness = centerStiffness
        self.zoomStiffness = zoomStiffness
    }
}

/// One stretch of zoomed-in camera, however it was decided: detected from
/// clicks or authored by the user on the timeline.
struct CameraShot {
    var start: TimeInterval
    var end: TimeInterval
    var zoom: Double
    /// Fixed point the shot is composed around, if it has one.
    var anchorX: Double?
    var anchorY: Double?
    /// How much the anchor pulls the frame against the live cursor position.
    var anchorWeight: Double
    /// Multiplier on the center spring stiffness while this shot is active,
    /// so a segment can be smoother or snappier than the default follow.
    var stiffnessScale: Double

    init(
        start: TimeInterval,
        end: TimeInterval,
        zoom: Double,
        anchorX: Double? = nil,
        anchorY: Double? = nil,
        anchorWeight: Double,
        stiffnessScale: Double = 1
    ) {
        self.start = start
        self.end = end
        self.zoom = zoom
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.anchorWeight = anchorWeight
        self.stiffnessScale = stiffnessScale
    }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }
}

/// Builds the camera path after recording, from the cursor track alone.
///
/// The tracker and the camera stay separate on purpose: the camera never reacts
/// to a raw event, only to the smoothed path plus the detected focus segments.
public struct CameraPathGenerator: Sendable {
    public var config: CameraConfig
    public var focusDetector: FocusDetector
    public var smoother: CursorPathSmoother

    public init(
        config: CameraConfig = CameraConfig(),
        focusDetector: FocusDetector = FocusDetector(),
        smoother: CursorPathSmoother = CursorPathSmoother()
    ) {
        self.config = config
        self.focusDetector = focusDetector
        self.smoother = smoother
    }

    /// Camera path from the automatically detected focus segments. Used by the
    /// CLI and as a fallback; the editor drives `generate(track:duration:focus:)`
    /// instead.
    public func generate(track: CursorTrack, duration: TimeInterval) -> CameraPath {
        let end = duration > 0 ? duration : track.duration
        let shots = focusDetector.segments(for: track, duration: end).map {
            CameraShot(
                start: $0.start,
                end: $0.end,
                zoom: config.focusZoom,
                anchorX: $0.anchorX,
                anchorY: $0.anchorY,
                anchorWeight: 0.35
            )
        }
        return generate(track: track, duration: end, shots: shots)
    }

    /// Camera path for one user-authored focus range: full frame outside it,
    /// zoomed in and following the cursor inside it, with the springs producing
    /// the ease in and out at the boundaries.
    public func generate(
        track: CursorTrack,
        duration: TimeInterval,
        focus: FocusRange?
    ) -> CameraPath {
        let shots = focus.map {
            [CameraShot(start: $0.start, end: $0.end, zoom: max(1, $0.zoom), anchorWeight: 0)]
        } ?? []
        return generate(track: track, duration: duration, shots: shots)
    }

    /// Camera path for the editor's effect segments: full frame outside them,
    /// and inside each segment either a fixed zoom onto its focal point or a
    /// cursor follow with its own smoothing. Segments must be sorted and
    /// non-overlapping (`EffectSegment.resolved` guarantees this).
    public func generate(
        track: CursorTrack,
        duration: TimeInterval,
        segments: [EffectSegment]
    ) -> CameraPath {
        let shots = segments.map { segment -> CameraShot in
            switch segment.kind {
            case .zoom:
                // Fully anchored: the frame composes around the chosen focal
                // point and ignores the live cursor.
                return CameraShot(
                    start: segment.start,
                    end: segment.end,
                    zoom: max(1, segment.zoom),
                    anchorX: segment.centerX,
                    anchorY: segment.centerY,
                    anchorWeight: 1
                )
            case .followCursor:
                // smoothing 0...1 maps to a stiffer or softer center spring:
                // 0 doubles the default stiffness, 1 halves it.
                let scale = pow(2, (0.5 - segment.smoothing) * 2)
                return CameraShot(
                    start: segment.start,
                    end: segment.end,
                    zoom: max(1, segment.zoom),
                    anchorWeight: 0,
                    stiffnessScale: scale
                )
            }
        }
        return generate(track: track, duration: duration, shots: shots)
    }

    private func generate(
        track: CursorTrack,
        duration: TimeInterval,
        shots segments: [CameraShot]
    ) -> CameraPath {
        let end = duration > 0 ? duration : track.duration
        guard end > 0 else { return CameraPath(frameRate: config.frameRate, keyframes: []) }

        // With no cursor data there is nothing to follow, but a focus range
        // still has to zoom, so fall back to a centered path.
        let smoothed = smoother.smooth(track.resampled(hz: config.frameRate, duration: end))
        let path = smoothed.isEmpty ? centeredPath(duration: end) : smoothed
        guard !path.isEmpty else {
            return CameraPath(
                frameRate: config.frameRate,
                keyframes: [CameraKeyframe(time: 0, centerX: 0.5, centerY: 0.5, zoom: config.restZoom)]
            )
        }

        var centerX = Spring(value: 0.5, stiffness: config.centerStiffness)
        var centerY = Spring(value: 0.5, stiffness: config.centerStiffness)
        var zoom = Spring(value: config.restZoom, stiffness: config.zoomStiffness)

        var targetX = 0.5
        var targetY = 0.5
        var keyframes: [CameraKeyframe] = []
        keyframes.reserveCapacity(path.count)
        var previousTime = path[0].time
        var segmentIndex = 0

        for (index, sample) in path.enumerated() {
            let dt = index == 0 ? 1 / config.frameRate : sample.time - previousTime
            previousTime = sample.time

            while segmentIndex < segments.count && segments[segmentIndex].end < sample.time {
                segmentIndex += 1
            }
            let segment = segmentIndex < segments.count && segments[segmentIndex].contains(sample.time)
                ? segments[segmentIndex]
                : nil

            // Per-shot smoothing scales the center springs; the zoom spring
            // keeps its own timing so ease in/out stays consistent.
            let stiffness = config.centerStiffness * (segment?.stiffnessScale ?? 1)
            centerX.stiffness = stiffness
            centerY.stiffness = stiffness

            let targetZoom = segment?.zoom ?? config.restZoom
            zoom.advance(to: targetZoom, dt: dt)
            let currentZoom = max(1, zoom.value)

            if let segment {
                let velocity = self.velocity(in: path, at: index)
                let leadX = clamp(velocity.x * config.lookAhead, -config.maxLookAhead, config.maxLookAhead)
                let leadY = clamp(velocity.y * config.lookAhead, -config.maxLookAhead, config.maxLookAhead)
                // Anchor the shot on the interaction, but let the cursor pull
                // the frame as it moves within it. A user-authored range has no
                // anchor and follows the cursor alone.
                let weight = segment.anchorWeight
                let desiredX = (segment.anchorX ?? sample.x) * weight + (sample.x + leadX) * (1 - weight)
                let desiredY = (segment.anchorY ?? sample.y) * weight + (sample.y + leadY) * (1 - weight)
                // Dead zone: ignore movement that keeps the cursor comfortably
                // inside the current viewport. A fully anchored shot composes
                // exactly on its focal point, so the dead zone shrinks with
                // the anchor weight.
                let halfViewport = 0.5 / currentZoom
                let deadZone = config.deadZone * halfViewport * 2 * (1 - weight)
                if abs(desiredX - targetX) > deadZone {
                    targetX += desiredX - targetX - copysign(deadZone, desiredX - targetX)
                }
                if abs(desiredY - targetY) > deadZone {
                    targetY += desiredY - targetY - copysign(deadZone, desiredY - targetY)
                }
            } else {
                targetX = 0.5
                targetY = 0.5
            }

            // Clamp so the viewport never shows outside the captured frame. The
            // cursor is allowed to sit off-center near an edge - that is what
            // the eye expects.
            let half = 0.5 / currentZoom
            let clampedTargetX = clamp(targetX, half, 1 - half)
            let clampedTargetY = clamp(targetY, half, 1 - half)

            centerX.advance(to: clampedTargetX, dt: dt)
            centerY.advance(to: clampedTargetY, dt: dt)

            keyframes.append(
                CameraKeyframe(
                    time: sample.time,
                    centerX: clamp(centerX.value, half, 1 - half),
                    centerY: clamp(centerY.value, half, 1 - half),
                    zoom: currentZoom
                )
            )
        }

        return CameraPath(frameRate: config.frameRate, keyframes: keyframes)
    }

    private func centeredPath(duration: TimeInterval) -> [CursorSample] {
        let step = 1 / config.frameRate
        var samples: [CursorSample] = []
        var t: TimeInterval = 0
        while t <= duration + step / 2 {
            samples.append(CursorSample(time: t, x: 0.5, y: 0.5))
            t += step
        }
        return samples
    }

    private func velocity(in path: [CursorSample], at index: Int) -> (x: Double, y: Double) {
        guard index > 0 else { return (0, 0) }
        let current = path[index]
        let previous = path[index - 1]
        let dt = current.time - previous.time
        guard dt > 0 else { return (0, 0) }
        return ((current.x - previous.x) / dt, (current.y - previous.y) / dt)
    }
}

@inlinable
func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    guard upper > lower else { return (lower + upper) / 2 }
    return min(max(value, lower), upper)
}
