#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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

    public static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    public static func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: return hasScreenRecording
        case .inputMonitoring: return hasInputMonitoring
        }
    }

    /// Shows the system prompt if macOS has never asked for this permission.
    /// Returns whether it is granted right now: after the user flips the switch
    /// macOS restarts the app, so a `false` here is normal and not an error.
    @discardableResult
    public static func request(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: return CGRequestScreenCaptureAccess()
        case .inputMonitoring: return CGRequestListenEventAccess()
        }
    }

    public static func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    public static var missing: [Permission] {
        Permission.allCases.filter { !isGranted($0) }
    }
}
#endif
