import Foundation

/// The full pointer recording for one capture, in the recording's timebase.
public struct CursorTrack: Codable, Equatable, Sendable {
    public var events: [CursorEvent]

    public init(events: [CursorEvent] = []) {
        self.events = events
    }

    public var duration: TimeInterval {
        events.last?.time ?? 0
    }

    /// Merges the event-tap stream with the periodic sampler stream.
    ///
    /// The event tap is the source of truth for the movement path; samples only
    /// exist to recover from coalesced or dropped events, so a sample is kept
    /// only when it reports a position the event stream does not already
    /// describe.
    public static func merge(
        tapEvents: [CursorEvent],
        samples: [CursorEvent],
        positionEpsilon: Double = 0.001
    ) -> CursorTrack {
        var merged = (tapEvents + samples).sorted { lhs, rhs in
            if lhs.time == rhs.time { return lhs.type == .sample && rhs.type != .sample }
            return lhs.time < rhs.time
        }

        var kept: [CursorEvent] = []
        kept.reserveCapacity(merged.count)
        var lastPosition: (x: Double, y: Double)?
        for event in merged {
            if event.type == .sample, let last = lastPosition,
               abs(event.x - last.x) < positionEpsilon, abs(event.y - last.y) < positionEpsilon {
                continue
            }
            kept.append(event)
            lastPosition = (event.x, event.y)
        }
        merged = kept
        return CursorTrack(events: merged)
    }

    /// Position at an arbitrary time, linearly interpolated between the two
    /// surrounding observations.
    public func position(at time: TimeInterval) -> (x: Double, y: Double)? {
        guard let first = events.first, let last = events.last else { return nil }
        if time <= first.time { return (first.x, first.y) }
        if time >= last.time { return (last.x, last.y) }

        var low = 0
        var high = events.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if events[mid].time <= time { low = mid } else { high = mid }
        }
        let a = events[low]
        let b = events[high]
        let span = b.time - a.time
        guard span > 0 else { return (b.x, b.y) }
        let t = (time - a.time) / span
        return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }

    /// Uniformly resampled path, which is what the camera engine consumes.
    public func resampled(hz: Double, duration: TimeInterval? = nil) -> [CursorSample] {
        guard hz > 0, !events.isEmpty else { return [] }
        let end = duration ?? self.duration
        guard end > 0 else { return [] }
        let step = 1 / hz
        var result: [CursorSample] = []
        result.reserveCapacity(Int(end * hz) + 1)
        var t: TimeInterval = 0
        while t <= end + step / 2 {
            if let point = position(at: t) {
                result.append(CursorSample(time: t, x: point.x, y: point.y))
            }
            t += step
        }
        return result
    }
}

/// A point on the uniformly resampled cursor path.
public struct CursorSample: Equatable, Sendable {
    public var time: TimeInterval
    public var x: Double
    public var y: Double

    public init(time: TimeInterval, x: Double, y: Double) {
        self.time = time
        self.x = x
        self.y = y
    }
}

/// Thread-safe sink the event tap and the sampler push into.
///
/// `append` is deliberately trivial: the tap callback timestamps, converts and
/// enqueues, then returns immediately so it never delays event delivery.
public final class CursorEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CursorEvent] = []

    public init(reservingCapacity capacity: Int = 8192) {
        storage.reserveCapacity(capacity)
    }

    public func append(_ event: CursorEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    public func snapshot() -> [CursorEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func drain() -> [CursorEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = storage
        storage.removeAll(keepingCapacity: true)
        return events
    }
}
