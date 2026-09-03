#if os(macOS)
import CoreMedia
import Darwin
import Foundation
import SwayCore

/// Bridges the two Mach clocks Sway has to reconcile.
///
/// `Timebase` (and therefore every cursor event) runs on
/// `mach_continuous_time`, while ScreenCaptureKit stamps sample buffers with
/// the host time clock, which is `mach_absolute_time`. The two differ by the
/// time the machine has spent asleep, so the offset is measured once at
/// recording start and applied to every presentation timestamp.
public struct HostClockBridge: Sendable {
    public let timebase: Timebase
    /// continuous - absolute, in seconds, measured at construction.
    public let continuousMinusAbsolute: Double

    public init(timebase: Timebase) {
        self.timebase = timebase
        self.continuousMinusAbsolute = Timebase.hostSeconds() - HostClockBridge.absoluteSeconds()
    }

    /// Recording-relative time for a ScreenCaptureKit presentation timestamp.
    public func relativeTime(forPresentationTime pts: CMTime) -> TimeInterval {
        let absolute = CMTimeGetSeconds(pts)
        guard absolute.isFinite else { return timebase.elapsed() }
        return (absolute + continuousMinusAbsolute) - timebase.startSeconds
    }

    public static func absoluteSeconds() -> Double {
        Double(mach_absolute_time()) * HostClockBridge.secondsPerTick
    }

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}
#endif
