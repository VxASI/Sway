import CoreGraphics
import SwayCapture
import SwiftUI

/// The picker shown after Record: every display and window with a live
/// thumbnail, its name, and a clear selected state.
struct CapturePickerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    private var filteredSources: [CaptureSource] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.sources }
        return model.sources.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            header
            TextField("Find a screen, window or app", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .accessibilityLabel("Search capture sources")
            Divider()
            if let error = model.sourcesError {
                failure(error)
            } else if model.isLoadingSources && model.sources.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for screens and windows…")
                        .foregroundStyle(.secondary)
                    // Every path out of this state is bounded, but say so:
                    // a spinner with no way out is what this screen is for.
                    Button("Cancel") { model.cancelPicking() }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sources.isEmpty {
                failure("""
                macOS reported nothing that can be recorded. If you just granted \
                Screen Recording, quit and reopen Sway - the grant only applies \
                to a fresh launch.
                """)
            } else if filteredSources.isEmpty {
                VStack(spacing: 12) {
                    Text("No matching screens or windows")
                        .font(.headline)
                    Text("Try a window title or app name.")
                        .foregroundStyle(.secondary)
                    Button("Clear Search") { searchText = "" }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        section("Screens", sources: filteredSources.filter { $0.kind == .display })
                        section("Windows", sources: filteredSources.filter { $0.kind == .window })
                    }
                    .padding(20)
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("Choose what to record")
                .font(.title2.weight(.semibold))
            Spacer()
            if model.isLoadingSources {
                ProgressView().controlSize(.small)
            }
            Button {
                model.reloadSources()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.isLoadingSources)
        }
        .padding(20)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source = model.selectedSource {
                HStack {
                    Text("Selected: \(source.name)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("Starts after a 3-second countdown")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            HStack(spacing: 18) {
                Button("Cancel") { model.cancelPicking() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Picker("Frame rate", selection: $model.recordingFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .labelsHidden()
                .help("Capture frame rate")

                Toggle(isOn: $model.capturesSystemAudio) {
                    Label("System Audio", systemImage: "speaker.wave.2")
                }
                .toggleStyle(.checkbox)
                .help("Record the Mac's audio output alongside the screen")

                Button("Start Recording") { model.startRecording() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedSource == nil)
            }
        }
        .padding(20)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button("Try Again") { model.reloadSources() }
                Button("Permissions") { model.showPermissions() }
                Button("Open Privacy Settings") {
                    model.permissions.openSettings(for: .screenRecording)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section(_ title: String, sources: [CaptureSource]) -> some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(sources) { source in
                        Button {
                            model.selectedSourceID = source.id
                        } label: {
                            CaptureSourceTile(
                                source: source,
                                thumbnail: model.thumbnails[source.id],
                                isSelected: model.selectedSourceID == source.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(source.name), \(source.subtitle)")
                        .accessibilityValue(model.selectedSourceID == source.id ? "Selected" : "Not selected")
                        .help("Select \(source.name)")
                    }
                }
            }
        }
    }
}

private struct CaptureSourceTile: View {
    let source: CaptureSource
    let thumbnail: CGImage?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.25))
                if let thumbnail {
                    Image(thumbnail, scale: 1, label: Text(source.name))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: source.kind == .display ? "display" : "macwindow")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 130)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 3 : 1)
            }

            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .lineLimit(1)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                    Text(source.subtitle)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
