import Foundation

/// Critically damped spring integrator used for both the camera center and the
/// zoom level, so the camera eases into place instead of snapping.
public struct Spring: Sendable {
    public var stiffness: Double
    public var dampingRatio: Double
    public private(set) var value: Double
    public private(set) var velocity: Double

    public init(value: Double, stiffness: Double = 90, dampingRatio: Double = 1.0) {
        self.value = value
        self.velocity = 0
        self.stiffness = stiffness
        self.dampingRatio = dampingRatio
    }

    public mutating func advance(to target: Double, dt: Double) {
        guard dt > 0 else { return }
        let damping = 2 * dampingRatio * stiffness.squareRoot()
        // Sub-step so a large dt (or a stiff spring) cannot make the
        // integration blow up.
        let steps = max(1, Int((dt / 0.008).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let acceleration = -stiffness * (value - target) - damping * velocity
            velocity += acceleration * h
            value += velocity * h
        }
    }

    public mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}

/// Exponential smoothing of the raw cursor path, applied before focus detection
/// so that hand jitter does not read as movement.
public struct CursorPathSmoother: Sendable {
    public var timeConstant: TimeInterval

    public init(timeConstant: TimeInterval = 0.06) {
        self.timeConstant = timeConstant
    }

    public func smooth(_ samples: [CursorSample]) -> [CursorSample] {
        guard var previous = samples.first, timeConstant > 0 else { return samples }
        var result: [CursorSample] = [previous]
        result.reserveCapacity(samples.count)
        for sample in samples.dropFirst() {
            let dt = max(0, sample.time - previous.time)
            let alpha = 1 - exp(-dt / timeConstant)
            let smoothed = CursorSample(
                time: sample.time,
                x: previous.x + (sample.x - previous.x) * alpha,
                y: previous.y + (sample.y - previous.y) * alpha
            )
            result.append(smoothed)
            previous = smoothed
        }
        return result
    }
}
