#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// The two TCC permissions a Sway recording needs, checked before anything is
/// started rather than discovered as a hang or a failed recording.
///
/// - Screen Recording: ScreenCaptureKit, for both the picker's window list and
///   the capture itself.
/// - Input Monitoring: the listen-only `CGEventTap` that records the cursor.
public enum CapturePermissions {
    public enum Permission: String, CaseIterable, Sendable {
        case screenRecording
        case inputMonitoring

        public var title: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        public var reason: String {
            switch self {
            case .screenRecording:
                return "Lets Sway list your displays and windows, and record the one you pick."
            case .inputMonitoring:
                return "Lets Sway record cursor movement and clicks, which drive the camera."
            }
        }

        /// Deep link to this permission's list in System Settings.
        public var settingsURL: URL? {
            switch self {
            case .screenRecording:
                return URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            case .inputMonitoring:
                return URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
            }
        }
    }

    /// Whether a permission is granted, or `nil` when it could not be decided
    /// in time.
    ///
    /// This deliberately does **not** use `CGPreflightScreenCaptureAccess` or
    /// `CGPreflightListenEventAccess`: when the app's TCC record is in a
    /// half-granted state those calls can block indefinitely no matter which
    /// thread they run on. Each permission is decided instead by attempting the
    /// cheapest form of the thing it actually protects.
    public static func status(
        _ permission: Permission,
        timeout: TimeInterval = 5
    ) async -> Bool? {
        switch permission {
        case .screenRecording:
            // Listing shareable content is the same gate recording goes
            // through, and it fails with an error rather than blocking.
            return await bounded(permission, timeout: timeout) {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )
                    return true
                } catch {
                    log.info("screen recording probe failed: \(error, privacy: .public)")
                    return false
                }
            }
        case .inputMonitoring:
            // Creating the listen-only tap is exactly what the cursor recorder
            // does, and it returns nil instead of blocking when denied.
            return await bounded(permission, timeout: timeout) {
                guard let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                    callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                    userInfo: nil
                ) else { return false }
                CFMachPortInvalidate(tap)
                return true
            }
        }
    }

    /// Runs a probe with a deadline so no permission question can freeze the UI.
    private static func bounded(
        _ permission: Permission,
        timeout: TimeInterval,
        probe: @escaping @Sendable () async -> Bool
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await probe() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                log.error("\(permission.rawValue, privacy: .public) probe timed out")
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// The permissions known to be missing. An unknown (timed out) answer is
    /// treated as granted so a slow TCC daemon cannot block the user from
    /// trying: the capture itself still fails loudly if it really is missing.
    public static func missing() async -> [Permission] {
        var result: [Permission] = []
        for permission in Permission.allCases where await status(permission) == false {
            result.append(permission)
        }
        return result
    }

    /// Asks macOS for the permission.
    ///
    /// This is the same probe as ``status(_:)`` on purpose: attempting the
    /// protected operation is what makes macOS show its prompt, and unlike
    /// `CGRequestScreenCaptureAccess` / `CGRequestListenEventAccess` it cannot
    /// wedge the app waiting on a dialog that may never come. A `false` right
    /// after the user allows it is expected - macOS applies the grant on the
    /// next launch.
    @discardableResult
    public static func request(_ permission: Permission) async -> Bool {
        log.info("requesting \(permission.rawValue, privacy: .public)")
        let granted = await status(permission, timeout: 60) ?? false
        log.info("\(permission.rawValue, privacy: .public) granted: \(granted, privacy: .public)")
        return granted
    }

    public static let log = Logger(subsystem: "ai.sway.Sway", category: "permissions")

    public static func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

}
#endif
