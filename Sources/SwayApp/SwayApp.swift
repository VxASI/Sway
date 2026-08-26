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

        // While recording, the main window is hidden and the menu bar item is
        // the only piece of Sway on screen.
        MenuBarExtra("Sway", systemImage: "record.circle.fill", isInserted: $model.isRecording) {
            Text(model.elapsedLabel)
            Divider()
            Button("Stop Recording (⇧⌘S)") { model.stopRecording() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                WelcomeView()
            case .picking:
                CapturePickerView()
            case .recording:
                RecordingPlaceholderView()
            case .processing:
                ProcessingView()
            case .editing:
                EditorView()
            }
        }
        .alert("Sway", isPresented: model.errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Sway")
                .font(.largeTitle.weight(.semibold))
            Text("Record a display or a window, then add a focus range.")
                .foregroundStyle(.secondary)
            Button("Record") { model.showPicker() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            Button("Open Recording…") { model.openBundle() }
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
