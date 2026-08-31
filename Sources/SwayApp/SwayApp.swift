import SwiftUI

@main
struct SwayApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { model.showPicker() }
                    .keyboardShortcut("n")
                    .disabled(model.isBusy)
                Button("Stop Recording") { model.stopRecording() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.isRecording)
            }
        }

        // No `MenuBarExtra` here on purpose. Its `isInserted:` binding drives
        // SwiftUI into an endless update loop when it is backed by a published
        // property, which pegs the main thread at 100% CPU and beachballs the
        // window. The floating panel is the recording control instead.
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                WelcomeView()
            case .permissions:
                PermissionsView()
            case .picking:
                CapturePickerView()
            case .countdown:
                CountdownPlaceholderView()
            case .recording:
                RecordingPlaceholderView()
            case .processing:
                ProcessingView()
            case .editing:
                EditorView()
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
        .alert("Sway", isPresented: model.errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The welcome screen doubles as the recordings library: record something new,
/// or reopen anything made before.
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sway")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Record your screen, then direct the camera afterwards.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 36)

                HStack(spacing: 12) {
                    Button {
                        model.showPicker()
                    } label: {
                        Label("Record", systemImage: "record.circle")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)

                    Button("Open Recording…") { model.openBundle() }
                        .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Recent recordings")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    LibraryGrid()
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshLibrary() }
    }
}

struct CountdownPlaceholderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Starting recording…")
                .foregroundStyle(.secondary)
            Button("Cancel") { model.cancelCountdown() }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProcessingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Processing recording…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingPlaceholderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Text(model.elapsedLabel)
                .font(.system(size: 44, weight: .medium, design: .monospaced))
            Text("Recording. Press ⇧⌘S or use the floating control to stop.")
                .foregroundStyle(.secondary)
            Button("Stop") { model.stopRecording() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
