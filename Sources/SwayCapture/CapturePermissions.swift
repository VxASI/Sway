#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
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
    /// macOS wants the app relaunched, so a `false` here is normal.
    ///
    /// `CGRequestScreenCaptureAccess` and `CGRequestListenEventAccess` block the
    /// calling thread until the user dismisses the system dialog, so they are
    /// run off the main thread - calling them from the main thread beachballs
    /// the whole app behind the prompt.
    @discardableResult
    public static func request(_ permission: Permission) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                log.info("requesting \(permission.rawValue, privacy: .public)")
                let granted: Bool
                switch permission {
                case .screenRecording: granted = CGRequestScreenCaptureAccess()
                case .inputMonitoring: granted = CGRequestListenEventAccess()
                }
                log.info(
                    "\(permission.rawValue, privacy: .public) granted: \(granted, privacy: .public)"
                )
                continuation.resume(returning: granted)
            }
        }
    }

    public static let log = Logger(subsystem: "ai.sway.Sway", category: "permissions")

    public static func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    public static var missing: [Permission] {
        Permission.allCases.filter { !isGranted($0) }
    }
}
#endif
