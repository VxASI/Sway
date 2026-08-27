import AppKit
import Combine
import CoreGraphics
import Foundation
import SwayCapture
import SwayCore
import SwiftUI
import os

/// Drives the whole product flow: permissions, pick a source, record, process,
/// edit, export.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case permissions
        case picking
        case recording
        case processing
        case editing
    }

    @Published var phase: Phase = .idle
    @Published var sources: [CaptureSource] = []
    @Published var thumbnails: [String: CGImage] = [:]
    @Published var selectedSourceID: String?
    @Published var isLoadingSources = false
    /// Shown inside the picker: a hang-free failure is still a failure the user
    /// has to be able to see and retry.
    @Published var sourcesError: String?
    let permissions = PermissionMonitor()
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var editor: EditorModel?

    private let catalog = CaptureSourceCatalog()
    private var session: RecordingSession?
    private var recordingControl: RecordingControlPanel?
    private var timer: AnyCancellable?
    private var hotKey: StopHotKey?
    private var thumbnailTask: Task<Void, Never>?
    private var permissionsObserver: AnyCancellable?
    private let log = Logger(subsystem: "ai.sway.Sway", category: "app")

    init() {
        // The monitor is a separate object, so its changes have to be forwarded
        // for views observing the model alone to update.
        permissionsObserver = permissions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        log.info("app model ready")
    }

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

    // MARK: - Permissions

    /// Record goes straight to the picker and starts listing sources.
    ///
    /// No permission check gates this: listing the sources *is* the permission
    /// check, it is the operation the user asked for, and it is bounded. Asking
    /// a possibly-unresponsive TCC daemon first only adds a way to get stuck
    /// before anything useful has happened.
    func showPicker() {
        log.info("record tapped")
        phase = .picking
        reloadSources()
    }

    func showPermissions() {
        phase = .permissions
        permissions.startPolling()
    }

    func leavePermissions() {
        permissions.stopPolling()
        phase = editor == nil ? .idle : .editing
    }

    /// Called by the permissions screen once everything is usable.
    func permissionsSatisfied() {
        permissions.stopPolling()
        phase = .picking
        reloadSources()
    }

    // MARK: - Picking

    func cancelPicking() {
        thumbnailTask?.cancel()
        phase = editor == nil ? .idle : .editing
    }

    func reloadSources() {
        isLoadingSources = true
        sourcesError = nil
        thumbnailTask?.cancel()
        Task {
            do {
                await catalog.invalidate()
                let loaded = try await catalog.sources(
                    excludingBundleIdentifiers: [AppModel.bundleIdentifier]
                )
                self.sources = loaded
                if self.selectedSource == nil {
                    self.selectedSourceID = loaded.first?.id
                }
                self.loadThumbnails(for: loaded)
            } catch CaptureSourceError.screenRecordingPermissionMissing {
                self.showPermissions()
            } catch {
                self.sourcesError = "\(error)"
            }
            self.isLoadingSources = false
        }
    }

    /// Thumbnails arrive one at a time after the list is already on screen; a
    /// screenshot per window is slow enough that waiting for all of them makes
    /// the picker look stuck.
    private func loadThumbnails(for sources: [CaptureSource]) {
        thumbnails = [:]
        thumbnailTask = Task {
            for source in sources {
                if Task.isCancelled { return }
                if let image = await catalog.thumbnail(for: source.target) {
                    self.thumbnails[source.id] = image
                }
            }
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
                await self.permissions.refresh()
                if self.permissions.isReadyToRecord {
                    self.errorMessage = "Could not start recording.\n\n\(error)"
                    self.phase = .picking
                } else {
                    self.showPermissions()
                }
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
