#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import os

/// The two TCC permissions a recording needs, and the awkward facts about how
/// macOS grants them.
///
/// - Screen Recording (`kTCCServiceScreenCapture`) gates ScreenCaptureKit. The
///   grant does **not** take effect in the process the user granted it from:
///   `SCShareableContent` keeps failing, or hangs, until the app is relaunched.
///   That is why a granted-mid-session state is tracked separately.
/// - Input Monitoring (`kTCCServiceListenEvent`) gates the `CGEventTap` that
///   records the cursor. This one does take effect live.
///
/// Neither has an Info.plist usage string; the system dialog is built from
/// `CFBundleDisplayName`.
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

        /// Whether macOS only applies a new grant to the next launch.
        public var needsRelaunchAfterGranting: Bool {
            self == .screenRecording
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

    public static let log = Logger(subsystem: "ai.sway.Sway", category: "permissions")

    /// Whether the permission is granted, or `nil` if the system did not answer
    /// in time.
    ///
    /// Deliberately avoids `CGPreflightScreenCaptureAccess`. That call is a
    /// round trip to the TCC daemon, and on a machine whose `tccd` is unhappy -
    /// which is easy to provoke by force-quitting an app mid-prompt - it simply
    /// never returns. Screen Recording is inferred from the window server
    /// instead, which is local, instant, and never prompts.
    ///
    /// Everything still runs off the main thread with a deadline, and an
    /// unanswered check reports `nil` rather than a denial: "macOS won't say"
    /// and "you said no" need different things from the user.
    public static func preflight(
        _ permission: Permission,
        timeout: TimeInterval = 3
    ) async -> Bool? {
        await bounded(permission, timeout: timeout) {
            switch permission {
            case .screenRecording: return canReadOtherWindowTitles()
            case .inputMonitoring: return CGPreflightListenEventAccess()
            }
        }
    }

    /// Screen Recording, inferred from what the window server is willing to
    /// tell us.
    ///
    /// Window *titles* belonging to other applications are only readable with
    /// Screen Recording permission; without it the list still comes back, but
    /// with the names stripped. Windows owned by Sway, and by processes we
    /// cannot inspect (the window server's own menu bar windows), prove
    /// nothing and are skipped.
    private static func canReadOtherWindowTitles() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  NSRunningApplication(processIdentifier: pid) != nil else { continue }
            if let title = window[kCGWindowName as String] as? String, !title.isEmpty {
                return true
            }
        }
        return false
    }

    /// Asks macOS to show its permission dialog. Returns once the user has
    /// answered, or once `timeout` passes - the dialog is modal to the system,
    /// not to Sway, and the user may simply ignore it.
    ///
    /// A `true` here does not mean capture works yet: see
    /// ``Permission/needsRelaunchAfterGranting``.
    @discardableResult
    public static func request(
        _ permission: Permission,
        timeout: TimeInterval = 120
    ) async -> Bool? {
        log.info("requesting \(permission.rawValue, privacy: .public)")
        let granted = await bounded(permission, timeout: timeout) {
            switch permission {
            case .screenRecording: return CGRequestScreenCaptureAccess()
            case .inputMonitoring: return CGRequestListenEventAccess()
            }
        }
        log.info(
            "\(permission.rawValue, privacy: .public) request answered: \(String(describing: granted), privacy: .public)"
        )
        return granted
    }

    public static func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Runs a blocking TCC call on a background queue with a deadline, so no
    /// permission question can ever hold up the app.
    private static func bounded(
        _ permission: Permission,
        timeout: TimeInterval,
        work: @escaping @Sendable () -> Bool
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: work())
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                log.error("\(permission.rawValue, privacy: .public) call timed out")
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
#endif
