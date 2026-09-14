import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Monotonic clock shared by the screen capture pipeline and the cursor tracker.
///
/// Every recorded artifact - video frame presentation timestamps, cursor events,
/// audio - is stored as an offset from `startHostTime`, so nothing depends on
/// wall-clock time, which can jump when the system clock is adjusted.
public struct Timebase: Sendable {
    /// Host time (in seconds) captured when the recording started.
    public let startSeconds: Double

    public init(startSeconds: Double) {
        self.startSeconds = startSeconds
    }

    /// Starts a timebase at the current host time.
    public static func now() -> Timebase {
        Timebase(startSeconds: Timebase.hostSeconds())
    }

    /// Seconds elapsed since the recording started, for a given host timestamp.
    public func relative(toHostSeconds hostSeconds: Double) -> TimeInterval {
        hostSeconds - startSeconds
    }

    /// Seconds elapsed since the recording started, measured right now.
    public func elapsed() -> TimeInterval {
        Timebase.hostSeconds() - startSeconds
    }

    /// Current value of the monotonic host clock, in seconds.
    ///
    /// On Apple platforms this is `mach_continuous_time` (keeps counting across
    /// sleep, matches the clock behind `CMClockGetHostTimeClock`); elsewhere it
    /// is `CLOCK_MONOTONIC`.
    public static func hostSeconds() -> Double {
        #if canImport(Darwin)
        return Double(mach_continuous_time()) * Timebase.machSecondsPerTick
        #else
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
        #endif
    }

    #if canImport(Darwin)
    private static let machSecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    #endif
}
