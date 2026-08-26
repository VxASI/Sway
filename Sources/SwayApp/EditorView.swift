import AVKit
import SwayCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let editor = model.editor {
            EditorContentView(editor: editor)
        } else {
            WelcomeView()
        }
    }
}

private struct EditorContentView: View {
    @ObservedObject var editor: EditorModel
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: editor.player)
                .disabled(true)
                .aspectRatio(editor.project.geometry.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            transport
            Divider()
            FocusTimelineView(editor: editor)
                .frame(height: 96)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()
            controls
        }
        .alert("Sway", isPresented: alertBinding) {
            Button("OK", role: .cancel) { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage
                ?? editor.exportedURL.map { "Exported to \($0.path)" }
                ?? "")
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                editor.togglePlayback()
            } label: {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(editor.isPlaying ? "Pause" : "Play")

            Text(EditorContentView.timecode(editor.playhead))
                .font(.system(.body, design: .monospaced))
            Text("/ \(EditorContentView.timecode(editor.trimEnd))")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            if let focus = editor.focus {
                Button("Remove Focus") { editor.removeFocus() }
                HStack(spacing: 8) {
                    Text("Zoom")
                    Slider(
                        value: Binding(
                            get: { focus.zoom },
                            set: { editor.setZoom($0) }
                        ),
                        in: 1.2...4,
                        onEditingChanged: { if !$0 { editor.save() } }
                    )
                    .frame(width: 180)
                    Text(String(format: "%.1f×", focus.zoom))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 46, alignment: .leading)
                }
            } else {
                Button("Add Focus Range") { editor.addFocus() }
            }

            Spacer()

            Button("New Recording") { model.showPicker() }
            if editor.isExporting {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Export…") { editor.export() }
                .keyboardShortcut("e")
                .disabled(editor.isExporting)
        }
        .padding(20)
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { editor.errorMessage != nil || editor.exportedURL != nil },
            set: { _ in
                editor.errorMessage = nil
                editor.exportedURL = nil
            }
        )
    }

    static func timecode(_ time: TimeInterval) -> String {
        let total = max(0, time)
        return String(format: "%02d:%02d.%02d",
                      Int(total) / 60,
                      Int(total) % 60,
                      Int((total - total.rounded(.down)) * 100))
    }
}
