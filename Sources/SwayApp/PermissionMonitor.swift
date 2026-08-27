import AppKit
import Combine
import Foundation
import SwayCapture
import os

/// Tracks the state of the two TCC permissions and, crucially, whether Screen
/// Recording was granted *during this launch* - in which case ScreenCaptureKit
/// will not work until Sway is relaunched, no matter how long it waits.
@MainActor
final class PermissionMonitor: ObservableObject {
    enum Status: Equatable {
        /// Checked and refused, or never asked for.
        case denied
        /// Granted after this process started, so capture needs a relaunch.
        case grantedPendingRelaunch
        /// Granted before this process started: usable now.
        case granted
        /// The system did not answer. Shown as such rather than guessed at.
        case unknown

        var isUsable: Bool { self == .granted }
    }

    @Published private(set) var status: [CapturePermissions.Permission: Status] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var isRequesting: Set<CapturePermissions.Permission> = []

    /// Sticky record of "this permission was missing at some point during this
    /// launch", which is the only way to tell a fresh grant from an old one.
    private var wasMissing: Set<CapturePermissions.Permission> = []
    private var pollTask: Task<Void, Never>?
    private let log = Logger(subsystem: "ai.sway.Sway", category: "permissions")

    /// True only when everything needed to record works in this process.
    var isReadyToRecord: Bool {
        CapturePermissions.Permission.allCases.allSatisfy { self[$0].isUsable }
    }

    var needsRelaunch: Bool {
        status.values.contains(.grantedPendingRelaunch)
    }

    subscript(permission: CapturePermissions.Permission) -> Status {
        status[permission] ?? .unknown
    }

    func refresh() async {
        isChecking = true
        for permission in CapturePermissions.Permission.allCases {
            let granted = await CapturePermissions.preflight(permission)
            status[permission] = resolve(permission, granted: granted)
        }
        isChecking = false
        log.info("permissions: \(String(describing: self.status), privacy: .public)")
    }

    private func resolve(
        _ permission: CapturePermissions.Permission,
        granted: Bool?
    ) -> Status {
        switch granted {
        case .none:
            return .unknown
        case .some(false):
            wasMissing.insert(permission)
            return .denied
        case .some(true):
            guard wasMissing.contains(permission), permission.needsRelaunchAfterGranting else {
                return .granted
            }
            return .grantedPendingRelaunch
        }
    }

    /// Shows the system dialog. Never blocks the UI: the button becomes a
    /// spinner and the state refreshes when the user answers.
    func request(_ permission: CapturePermissions.Permission) {
        guard !isRequesting.contains(permission) else { return }
        isRequesting.insert(permission)
        Task {
            await CapturePermissions.request(permission)
            self.isRequesting.remove(permission)
            await self.refresh()
        }
    }

    func openSettings(for permission: CapturePermissions.Permission) {
        CapturePermissions.openSettings(for: permission)
    }

    /// Polls while the permissions screen is on show, so flipping the switch in
    /// System Settings updates Sway without the user coming back to click
    /// anything.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Quits and reopens Sway, which is the only way a new Screen Recording
    /// grant starts working.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
