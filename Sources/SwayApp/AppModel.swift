import AppKit
import Combine
import Foundation
import SwayCapture
import SwayCore
import SwiftUI

/// Drives the whole product flow: pick a source, record, process, edit, export.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case picking
        case recording
        case processing
        case editing
    }

    @Published var phase: Phase = .idle
    @Published var sources: [CaptureSource] = []
    @Published var selectedSourceID: String?
    @Published var isLoadingSources = false
    /// Bound by `MenuBarExtra`, so the menu bar item only exists while recording.
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var editor: EditorModel?

    private var session: RecordingSession?
    private var recordingControl: RecordingControlPanel?
    private var timer: AnyCancellable?
    private var hotKey: StopHotKey?

    var isBusy: Bool { phase == .recording || phase == .processing }

    var elapsedLabel: String {
        let total = Int(elapsed.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var errorBinding: Binding<Bool> {
        Binding(get: { self.errorMessage != nil }, set: { if !$0 { self.errorMessage = nil } })
    }

    var selectedSource: CaptureSource? {
        sources.first { $0.id == selectedSourceID }
    }

    // MARK: - Picking

    func showPicker() {
        phase = .picking
        reloadSources()
    }

    func cancelPicking() {
        phase = editor == nil ? .idle : .editing
    }

    func reloadSources() {
        isLoadingSources = true
        Task {
            do {
                let loaded = try await CaptureSourceCatalog.load(
                    excludingBundleIdentifiers: [AppModel.bundleIdentifier]
                )
                self.sources = loaded
                if self.selectedSource == nil {
                    self.selectedSourceID = loaded.first?.id
                }
            } catch {
                self.errorMessage = "Could not list what can be recorded. "
                    + "Grant Sway Screen Recording in System Settings > Privacy & Security.\n\n\(error)"
            }
            self.isLoadingSources = false
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard let source = selectedSource else { return }
        let options = ScreenRecorderOptions(
            target: source.target,
            frameRate: 60,
            capturesSystemAudio: false,
            excludedBundleIdentifiers: [AppModel.bundleIdentifier]
        )
        let session = RecordingSession(bundleURL: AppModel.newBundleURL(), options: options)
        self.session = session

        Task {
            do {
                try await session.start()
                self.phase = .recording
                self.isRecording = true
                self.elapsed = 0
                self.beginRecordingUI()
            } catch {
                self.session = nil
                self.errorMessage = "Could not start recording.\n\n\(error)"
                self.phase = .picking
            }
        }
    }

    func stopRecording() {
        guard let session, isRecording else { return }
        isRecording = false
        endRecordingUI()
        phase = .processing
        Task {
            do {
                let result = try await session.stop()
                self.session = nil
                self.editor = EditorModel(result: result)
                self.phase = .editing
            } catch {
                self.session = nil
                self.errorMessage = "Recording failed.\n\n\(error)"
                self.phase = .idle
            }
        }
    }

    private func beginRecordingUI() {
        // Sway is excluded from the capture, but hiding the main window also
        // keeps it out of the way while the user performs their actions.
        mainWindow?.orderOut(nil)

        let control = RecordingControlPanel { [weak self] in self?.stopRecording() }
        control.show()
        recordingControl = control

        hotKey = StopHotKey { [weak self] in self?.stopRecording() }

        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let session = self.session else { return }
                self.elapsed = session.elapsed
                self.recordingControl?.update(elapsed: self.elapsed)
            }
    }

    private func endRecordingUI() {
        timer?.cancel()
        timer = nil
        hotKey = nil
        recordingControl?.close()
        recordingControl = nil
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Opening

    func openBundle() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.message = "Choose a .sway recording"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = SwayProjectBundle(url: url)
            let project = try bundle.readProject()
            let track = try bundle.readCursorTrack()
            let edit = (try? bundle.readEdit())
                ?? SwayEdit.initial(duration: project.duration, track: track)
            editor = EditorModel(
                result: RecordingResult(bundle: bundle, project: project, track: track, edit: edit)
            )
            phase = .editing
        } catch {
            errorMessage = "Could not open that recording.\n\n\(error)"
        }
    }

    // MARK: - Helpers

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "ai.sway.Sway"

    static func newBundleURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Sway", isDirectory: true)
        return directory.appendingPathComponent(
            "\(formatter.string(from: Date())).\(SwayProjectBundle.pathExtension)"
        )
    }
}
