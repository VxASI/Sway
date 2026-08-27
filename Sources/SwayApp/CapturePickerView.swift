import CoreGraphics
import SwayCapture
import SwiftUI

/// The picker shown after Record: every display and window with a live
/// thumbnail, its name, and a clear selected state.
struct CapturePickerView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.sourcesError {
                failure(error)
            } else if model.isLoadingSources && model.sources.isEmpty {
                ProgressView("Looking for screens and windows…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        section("Screens", sources: model.sources.filter { $0.kind == .display })
                        section("Windows", sources: model.sources.filter { $0.kind == .window })
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
        HStack {
            Button("Cancel") { model.cancelPicking() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Start Recording") { model.startRecording() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedSource == nil)
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
                Button("Open Privacy Settings") { model.openSettings(for: .screenRecording) }
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
                        CaptureSourceTile(
                            source: source,
                            thumbnail: model.thumbnails[source.id],
                            isSelected: model.selectedSourceID == source.id
                        )
                        .onTapGesture { model.selectedSourceID = source.id }
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
