import SwayCapture
import SwiftUI

/// Shown instead of the picker when a TCC permission is missing, so a denied
/// permission reads as an instruction rather than an empty or hung picker.
struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("Sway needs permission to record")
                .font(.title2.weight(.semibold))
            Text("Grant these in System Settings, then quit and reopen Sway. "
                + "macOS only applies the change to a fresh launch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            VStack(spacing: 12) {
                ForEach(CapturePermissions.Permission.allCases, id: \.self) { permission in
                    row(permission)
                }
            }
            .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button("Back") { model.cancelPermissions() }
                Button("Check Again") { model.recheckPermissions() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ permission: CapturePermissions.Permission) -> some View {
        let granted = !model.missingPermissions.contains(permission)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.headline)
                Text(permission.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                if model.requestingPermissions.contains(permission) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Ask") { model.requestPermission(permission) }
                }
                Button("Open Settings") { model.openSettings(for: permission) }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}
