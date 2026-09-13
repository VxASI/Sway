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
    @FocusState private var isProjectNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.white.opacity(0.06))

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    transport
                    SegmentTimelineView(editor: editor, scale: timelineScale)
                        .frame(height: 94)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                Divider().overlay(Color.white.opacity(0.06))
                InspectorSidebar(editor: editor)
                    .frame(width: 284)
            }
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
                .focused($isProjectNameFocused)
                .onChange(of: isProjectNameFocused) { focused in
                    if !focused { editor.commitProjectName() }
                }
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

            Text(EditorContentView.timecode(
                min(max(0, editor.playhead - editor.trimStart), editor.edit.trimmedDuration)
            ))
                .font(.system(.body, design: .monospaced))
            Text("/ \(EditorContentView.timecode(editor.edit.trimmedDuration))")
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


/// A persistent inspector beside the preview keeps effect and cursor controls
/// readable without compressing them into a single strip below the timeline.
private struct InspectorSidebar: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Inspector").font(.headline)
                sectionHeader("Selected Effect", icon: "slider.horizontal.3")
                segmentControls
                Divider()
                sectionHeader("Cursor", icon: "cursorarrow")
                cursorControls
                Divider()
                canvasButton
            }
            .padding(18)
        }
        .background(Color.white.opacity(0.03))
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: Segment

    @ViewBuilder
    private var segmentControls: some View {
        if let segment = editor.selectedSegment {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    segment.kind == .zoom ? "Zoom" : "Follow Cursor",
                    systemImage: segment.kind == .zoom ? "plus.magnifyingglass" : "cursorarrow.motionlines"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(segment.kind == .zoom ? Color.purple : Color.blue)

                slider(segment.kind == .zoom ? "Intensity" : "Zoom when unstacked", value: segment.zoom, in: 1.2...4,
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
                Button(role: .destructive) {
                    editor.removeSegment(id: segment.id)
                } label: {
                    Label("Remove Effect", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
        } else {
            Text("Select a segment in either timeline lane to edit it.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
        return VStack(alignment: .leading, spacing: 12) {
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
                    if shape == .custom, style.customImage == nil {
                        editor.importCursorImage()
                    } else {
                        update { $0.shape = shape }
                        editor.save()
                    }
                })) {
                    ForEach(CursorStyle.Shape.allCases) { shape in
                        if shape != .recorded || editor.hasRecordedShapes {
                            Text(shape.label).tag(shape)
                        }
                    }
                }
                .frame(width: 170)
                .help(editor.hasRecordedShapes
                    ? "Draw the pointer the system showed, one of Sway's shapes, or your own image"
                    : "This recording predates pointer-shape capture, so \"As recorded\" is unavailable")

                if style.shape.isTinted {
                    Picker("", selection: Binding(get: { style.tint }, set: { tint in
                        update { $0.tint = tint }
                        editor.save()
                    })) {
                        ForEach(CursorStyle.Tint.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Cursor color")
                }
                if style.shape == .recorded || style.shape == .halo {
                    Picker("", selection: Binding(get: { style.recordedColor }, set: { color in
                        update { $0.recordedColor = color }
                        editor.save()
                    })) {
                        ForEach(CursorStyle.RecordedColor.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .help("Recorded pointers are black on macOS; Light inverts them to match Sway's cursor")
                }
                if style.shape == .custom, let custom = style.customImage {
                    Button("Change…") { editor.importCursorImage() }
                    Picker("Hotspot", selection: Binding(
                        get: { hotspotChoice(custom) },
                        set: { choice in
                            update {
                                $0.customImage?.hotspotX = choice.point.x
                                $0.customImage?.hotspotY = choice.point.y
                            }
                            editor.save()
                        }
                    )) {
                        ForEach(HotspotChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(width: 170)
                    slider("Width", value: custom.pointWidth, in: 8...128,
                           format: { String(format: "%.0f pt", $0) }) { value in
                        update { $0.customImage?.pointWidth = value }
                    }
                }

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

    enum HotspotChoice: String, CaseIterable, Identifiable {
        case topLeft, center, topCenter
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topLeft: return "Top-left (arrow)"
            case .center: return "Center (dot)"
            case .topCenter: return "Top-center"
            }
        }
        var point: (x: Double, y: Double) {
            switch self {
            case .topLeft: return (0, 0)
            case .center: return (0.5, 0.5)
            case .topCenter: return (0.5, 0)
            }
        }
    }

    private func hotspotChoice(_ custom: CursorStyle.CustomImage) -> HotspotChoice {
        HotspotChoice.allCases.first {
            abs($0.point.x - custom.hotspotX) < 0.01 && abs($0.point.y - custom.hotspotY) < 0.01
        } ?? .topLeft
    }

    // MARK: Canvas

    private var canvasButton: some View {
        Button {
            var updated = editor.canvasStyle
            updated.isEnabled.toggle()
            editor.setCanvas(updated)
            editor.save()
        } label: {
            HStack {
                Label("Canvas", systemImage: editor.canvasStyle.isEnabled ? "rectangle.inset.filled" : "rectangle")
                Spacer()
                Text(editor.canvasStyle.isEnabled ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(editor.canvasStyle.isEnabled ? .accentColor : nil)
    }

    private func slider(
        _ label: String,
        value: Double,
        in range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(format(value)).monospacedDigit()
            }
            .font(.callout)
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                onEditingChanged: { if !$0 { editor.save() } }
            )
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
            // With the canvas on, the recording sits in the same card rect
            // the renderer uses (source aspect, centered inside the padding).
            let style = editor.canvasStyle
            let card = style.isEnabled
                ? style.contentRect(in: geometry.size, contentAspect: editor.project.geometry.aspectRatio)
                : CGRect(origin: .zero, size: geometry.size)
            let origin = card.origin
            let size = card.size
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
        .interactiveDismissDisabled(editor.isExporting)
        .onDisappear { editor.exportedURL = nil }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Dimensions", selection: $editor.exportSettings.sizePreset) {
                ForEach(ExportSettings.SizePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            Picker("Quality", selection: $editor.exportSettings.quality) {
                ForEach(ExportSettings.Quality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $editor.exportSettings.frameRate) {
                ForEach(ExportSettings.FrameRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .pickerStyle(.segmented)

            let size = editor.exportSettings.sizePreset.size ?? CGSize(
                width: editor.project.geometry.pixelWidth,
                height: editor.project.geometry.pixelHeight
            )
            Text("\(EditorContentView.timecode(editor.edit.trimmedDuration)) · \(Int(size.width)) × \(Int(size.height)) · MP4")
                .font(.callout.monospacedDigit())
            Text("Includes your camera effects, cursor and trim. Changing the aspect ratio crops the video to fit.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = editor.exportError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Could not export", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    Text(error).font(.caption).textSelection(.enabled)
                    Text("Your recording is unchanged. Retry or choose another location.")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }

            HStack {
                Button("Cancel") { editor.isExportSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(editor.exportError == nil ? "Export…" : "Retry Export…") {
                    editor.export(settings: editor.exportSettings)
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var exporting: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: editor.exportProgress)
            Text(editor.exportProgress >= 0.98
                 ? "Finishing your video…"
                 : "Rendering… \(Int(editor.exportProgress * 100))%")
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
                Button("Open Video") { editor.openExportedFile() }
                Button("Show in Finder") { editor.revealExportedFile() }
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
