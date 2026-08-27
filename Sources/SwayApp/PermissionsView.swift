import SwayCapture
import SwiftUI

/// The permission gate. Every state here is an explicit, actionable one: there
/// is no path through this screen that just spins.
struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel

    private var monitor: PermissionMonitor { model.permissions }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: monitor.needsRelaunch ? "arrow.clockwise.circle" : "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(monitor.needsRelaunch ? "Reopen Sway to finish" : "Sway needs permission to record")
                .font(.title2.weight(.semibold))
            Text(headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)

            VStack(spacing: 10) {
                ForEach(CapturePermissions.Permission.allCases, id: \.self, content: row)
            }
            .frame(maxWidth: 470)

            HStack(spacing: 12) {
                Button("Back") { model.leavePermissions() }
                if monitor.needsRelaunch {
                    Button("Reopen Sway") { monitor.relaunch() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Check Again") { Task { await monitor.refresh() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(monitor.isChecking)
                }
            }
            if monitor.isChecking {
                Text("Checking with macOS…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await monitor.refresh() }
        .onChange(of: monitor.isReadyToRecord) { ready in
            if ready { model.permissionsSatisfied() }
        }
        .onDisappear { monitor.stopPolling() }
    }

    private var headline: String {
        if monitor.needsRelaunch {
            return """
            macOS only applies a new Screen Recording permission to a fresh \
            launch, so Sway has to be reopened before it can capture anything.
            """
        }
        return "Grant these in System Settings. Sway picks up the change on its own."
    }

    @ViewBuilder
    private func row(_ permission: CapturePermissions.Permission) -> some View {
        let status = monitor[permission]
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: status))
                .foregroundStyle(tint(for: status))
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.headline)
                Text(detail(permission, status))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if monitor.isRequesting.contains(permission) {
                    ProgressView().controlSize(.small)
                } else if status == .denied {
                    Button("Ask") { monitor.request(permission) }
                        .buttonStyle(.borderedProminent)
                }
                if status != .granted {
                    Button("Open Settings") { monitor.openSettings(for: permission) }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(
        _ permission: CapturePermissions.Permission,
        _ status: PermissionMonitor.Status
    ) -> String {
        switch status {
        case .granted:
            return "Granted."
        case .grantedPendingRelaunch:
            return "Granted - takes effect after Sway is reopened."
        case .denied:
            return permission.reason
        case .unknown:
            return """
            macOS did not answer the permission check. If this persists, run \
            `killall -9 replayd` in Terminal and reopen Sway.
            """
        }
    }

    private func symbol(for status: PermissionMonitor.Status) -> String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .grantedPendingRelaunch: return "arrow.clockwise.circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func tint(for status: PermissionMonitor.Status) -> Color {
        switch status {
        case .granted: return .green
        case .grantedPendingRelaunch: return .orange
        case .denied: return .secondary
        case .unknown: return .yellow
        }
    }
}
