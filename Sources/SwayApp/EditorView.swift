import AVFoundation
import AppKit
import SwayCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let editor = model.editor {
            EditorContentView(editor: editor)
                .id(ObjectIdentifier(editor))
        } else {
            WelcomeView()
        }
    }
}

private struct EditorContentView: View {
    @ObservedObject var editor: EditorModel
    @EnvironmentObject private var model: AppModel
    @State private var timelineScale: CGFloat = 1
    @State private var smartFocusZoom: Double = 1.8

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.white.opacity(0.06))

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            transport
            SegmentTimelineView(editor: editor, scale: timelineScale)
                .frame(height: 78)
                .padding(.horizontal, 20)
            InspectorPanel(editor: editor)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .alert("Sway", isPresented: errorBinding) {
            Button("OK", role: .cancel) { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .sheet(isPresented: $editor.isExportSheetPresented) {
            ExportSheet(editor: editor)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button {
                editor.save()
                model.showLibrary()
            } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            TextField("Project name", text: $editor.projectName)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 280)
                .onSubmit { editor.commitProjectName() }

            Spacer()

            Button {
                model.showPicker()
            } label: {
                Label("Record", systemImage: "record.circle")
            }

            Button {
                editor.isExportSheetPresented = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e")
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Preview

    /// The player with, when a zoom segment is selected, a draggable reticle
    /// that sets the segment's focal point on the recording itself.
    private var preview: some View {
        PreviewView(editor: editor)
            .aspectRatio(editor.project.geometry.aspectRatio, contentMode: .fit)
            .overlay {
                if let segment = editor.selectedSegment, segment.kind == .zoom, !editor.isPlaying {
                    FocalPointOverlay(editor: editor, segment: segment)
                }
            }
            .padding(16)
    }

    // MARK: - Transport

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

            Menu {
                ForEach(EditorModel.SmartFocusMode.allCases) { mode in
                    Button(mode.label) { editor.applySmartFocus(mode: mode, zoom: smartFocusZoom) }
                }
                Divider()
                Picker("Zoom strength", selection: $smartFocusZoom) {
                    Text("Subtle 1.4×").tag(1.4)
                    Text("Medium 1.8×").tag(1.8)
                    Text("Strong 2.4×").tag(2.4)
                }
                Divider()
                Button("Clear All Segments", role: .destructive) { editor.clearSegments() }
            } label: {
                Label("Smart Focus", systemImage: "wand.and.stars")
            }
            .help("Generate camera moves from the recorded clicks or cursor")

            Button {
                editor.addSegment(kind: .zoom)
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            }
            .help("Add a zoom segment at the playhead")

            Button {
                editor.addSegment(kind: .followCursor)
            } label: {
                Label("Follow Cursor", systemImage: "cursorarrow.motionlines")
            }
            .help("Add a follow-cursor segment at the playhead")

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $timelineScale, in: 1...8)
                    .frame(width: 110)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .help("Timeline zoom")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { editor.errorMessage != nil },
            set: { if !$0 { editor.errorMessage = nil } }
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


/// The controls under the timeline, in three tabs so the editor stays compact:
/// the selected segment, the cursor, and the canvas.
private struct InspectorPanel: View {
    @ObservedObject var editor: EditorModel

    enum Tab: String, CaseIterable, Identifiable {
        case segment, cursor, canvas
        var id: String { rawValue }
        var label: String {
            switch self {
            case .segment: return "Segment"
            case .cursor: return "Cursor"
            case .canvas: return "Canvas"
            }
        }
    }

    @State private var tab: Tab = .segment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Group {
                switch tab {
                case .segment: segmentControls
                case .cursor: cursorControls
                case .canvas: canvasControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .onChange(of: editor.selectedSegmentID) { id in
            if id != nil { tab = .segment }
        }
    }

    // MARK: Segment

    @ViewBuilder
    private var segmentControls: some View {
        HStack(spacing: 16) {
            if let segment = editor.selectedSegment {
                Label(
                    segment.kind == .zoom ? "Zoom" : "Follow Cursor",
                    systemImage: segment.kind == .zoom ? "plus.magnifyingglass" : "cursorarrow.motionlines"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(segment.kind == .zoom ? Color.purple : Color.blue)

                slider("Intensity", value: segment.zoom, in: 1.2...4,
                       format: { String(format: "%.1f×", $0) }) { value in
                    var updated = segment
                    updated.zoom = value
                    editor.updateSegment(updated)
                }
                if segment.kind == .followCursor {
                    slider("Smoothing", value: segment.smoothing, in: 0...1,
                           format: { String(format: "%.0f%%", $0 * 100) }) { value in
                        var updated = segment
                        updated.smoothing = value
                        editor.updateSegment(updated)
                    }
                } else {
                    Text("Drag the ring on the preview to aim the zoom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    editor.removeSegment(id: segment.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } else {
                Text("Select a segment on the timeline, or add a Zoom or Follow Cursor effect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: Cursor

    private var cursorControls: some View {
        let style = editor.cursorStyle
        func update(_ change: (inout CursorStyle) -> Void) {
            var updated = style
            change(&updated)
            editor.setCursor(updated)
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Toggle("Show", isOn: Binding(get: { style.isVisible }, set: { on in
                    update { $0.isVisible = on }
                    editor.save()
                }))
                .toggleStyle(.switch)
                .controlSize(.small)

                slider("Size", value: style.size, in: 0.5...3,
                       format: { String(format: "%.1f×", $0) }) { value in update { $0.size = value } }
                slider("Smoothing", value: style.smoothing, in: 0...1,
                       format: { String(format: "%.0f%%", $0 * 100) }) { value in update { $0.smoothing = value } }

                Picker("Shape", selection: Binding(get: { style.shape }, set: { shape in
                    update { $0.shape = shape }
                    editor.save()
                })) {
                    ForEach(CursorStyle.Shape.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 170)
                .disabled(!editor.hasRecordedShapes)
                .help(editor.hasRecordedShapes
                    ? "Draw the pointer the system showed, or Sway's arrow"
                    : "This recording predates pointer-shape capture; the arrow is used")

                Toggle("Click rings", isOn: Binding(get: { style.clickRings }, set: { on in
                    update { $0.clickRings = on }
                    editor.save()
                }))
                .toggleStyle(.checkbox)
                if style.clickRings {
                    Picker("", selection: Binding(get: { style.ringColor }, set: { color in
                        update { $0.ringColor = color }
                        editor.save()
                    })) {
                        ForEach(CursorStyle.RingColor.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }

                Toggle("Spotlight", isOn: Binding(get: { style.spotlight }, set: { on in
                    update { $0.spotlight = on }
                    editor.save()
                }))
                .toggleStyle(.checkbox)

                Toggle("Hide when idle", isOn: Binding(get: { style.hideWhenIdle }, set: { on in
                    update { $0.hideWhenIdle = on }
                    editor.save()
                }))
                .toggleStyle(.checkbox)
                if style.hideWhenIdle {
                    slider("after", value: style.idleSeconds, in: 0.5...6,
                           format: { String(format: "%.1fs", $0) }) { value in update { $0.idleSeconds = value } }
                }

                Toggle("Hide while typing", isOn: Binding(get: { style.hideWhileTyping }, set: { on in
                    update { $0.hideWhileTyping = on }
                    editor.save()
                }))
                .toggleStyle(.checkbox)
                .disabled(!editor.recordsKeyPresses)
                .help(editor.recordsKeyPresses
                    ? "Fade the cursor out while keys are pressed"
                    : "No key presses were recorded in this recording")
            }
        }
    }

    // MARK: Canvas

    private var canvasControls: some View {
        let style = editor.canvasStyle
        func update(_ change: (inout CanvasStyle) -> Void) {
            var updated = style
            change(&updated)
            editor.setCanvas(updated)
        }
        return HStack(spacing: 16) {
            Toggle("Canvas", isOn: Binding(get: { style.isEnabled }, set: { on in
                update { $0.isEnabled = on }
                editor.save()
            }))
            .toggleStyle(.switch)
            .controlSize(.small)

            if style.isEnabled {
                Picker("", selection: Binding(get: { style.background }, set: { background in
                    update { $0.background = background }
                    editor.save()
                })) {
                    ForEach(CanvasStyle.Background.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)

                slider("Padding", value: style.padding, in: 0...0.2,
                       format: { String(format: "%.0f%%", $0 * 100) }) { value in update { $0.padding = value } }
                slider("Corners", value: style.cornerRadius, in: 0...0.1,
                       format: { String(format: "%.0f%%", $0 * 100) }) { value in update { $0.cornerRadius = value } }
                slider("Shadow", value: style.shadow, in: 0...1,
                       format: { String(format: "%.0f%%", $0 * 100) }) { value in update { $0.shadow = value } }
            } else {
                Text("Float the recording as a rounded card on a gradient background.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func slider(
        _ label: String,
        value: Double,
        in range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                onEditingChanged: { if !$0 { editor.save() } }
            )
            .frame(width: 120)
            Text(format(value))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 46, alignment: .leading)
        }
    }
}

/// A draggable ring over the preview that positions a zoom segment's focal
/// point. Coordinates map 1:1 onto the aspect-fitted video, which is exactly
/// the view this overlay sits on.
private struct FocalPointOverlay: View {
    @ObservedObject var editor: EditorModel
    let segment: EffectSegment

    var body: some View {
        GeometryReader { geometry in
            // With the canvas on, the recording sits inset by the padding.
            let style = editor.canvasStyle
            let inset = style.isEnabled
                ? min(geometry.size.width, geometry.size.height) * style.padding
                : 0
            let origin = CGPoint(x: inset, y: inset)
            let size = CGSize(
                width: geometry.size.width - inset * 2,
                height: geometry.size.height - inset * 2
            )
            ZStack {
                Circle()
                    .strokeBorder(Color.purple, lineWidth: 2)
                    .background(Circle().fill(Color.purple.opacity(0.15)))
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(Color.purple)
                    .frame(width: 6, height: 6)
            }
            .position(
                x: origin.x + segment.centerX * size.width,
                y: origin.y + segment.centerY * size.height
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        var updated = segment
                        updated.centerX = min(max(0, (value.location.x - origin.x) / max(size.width, 1)), 1)
                        updated.centerY = min(max(0, (value.location.y - origin.y) / max(size.height, 1)), 1)
                        editor.updateSegment(updated)
                    }
                    .onEnded { _ in editor.save() }
            )
        }
    }
}

/// Export options, progress and result, in one sheet so the user always knows
/// what state the export is in.
private struct ExportSheet: View {
    @ObservedObject var editor: EditorModel
    @State private var settings = ExportSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export")
                .font(.title2.weight(.semibold))

            if let exported = editor.exportedURL {
                success(exported)
            } else if editor.isExporting {
                exporting
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 380)
        .onDisappear { editor.exportedURL = nil }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Dimensions", selection: $settings.sizePreset) {
                ForEach(ExportSettings.SizePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            Picker("Quality", selection: $settings.quality) {
                ForEach(ExportSettings.Quality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $settings.frameRate) {
                ForEach(ExportSettings.FrameRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .pickerStyle(.segmented)

            Text("MP4 · zooms, cursor and trim are baked in exactly as previewed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { editor.isExportSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { editor.export(settings: settings) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var exporting: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: editor.exportProgress)
            Text("Rendering… \(Int(editor.exportProgress * 100))%")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func success(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Exported", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Button("Reveal in Finder") { editor.revealExportedFile() }
                Spacer()
                Button("Done") {
                    editor.exportedURL = nil
                    editor.isExportSheetPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
