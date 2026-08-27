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

    /// Whether a permission is granted.
    ///
    /// Never call this on the main thread: the preflight talks to the TCC
    /// daemon and the window server, and when either is busy or the app's
    /// record is in a half-granted state it can block for a long time - which
    /// on the main thread is a frozen window with a spinning cursor. Use
    /// ``status(_:)`` from the UI.
    public static func isGrantedBlocking(_ permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        }
    }

    /// Off-main-thread permission check, bounded so a wedged TCC daemon costs a
    /// second and an "unknown" answer rather than the whole app.
    public static func status(
        _ permission: Permission,
        timeout: TimeInterval = 2
    ) async -> Bool? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            let finish: @Sendable (Bool?) -> Void = { value in
                guard once.claim() else { return }
                continuation.resume(returning: value)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(isGrantedBlocking(permission))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                log.error(
                    "preflight for \(permission.rawValue, privacy: .public) timed out"
                )
                finish(nil)
            }
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

    /// Whichever of the check and the timeout finishes first resumes the
    /// continuation; the other must not.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    public static func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

}
#endif
