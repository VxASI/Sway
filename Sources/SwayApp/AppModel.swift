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
        case countdown
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

    // Recording setup, chosen in the picker.
    @Published var recordingFrameRate = 60
    @Published var capturesSystemAudio = true

    // Past recordings shown on the welcome screen.
    @Published var library: [LibraryItem] = []
    @Published var isLoadingLibrary = false

    private let catalog = CaptureSourceCatalog()
    private var session: RecordingSession?
    private var recordingControl: RecordingControlPanel?
    private var countdownPanel: CountdownPanel?
    private var countdownTask: Task<Void, Never>?
    private var timer: AnyCancellable?
    private var hotKey: StopHotKey?
    private var sourceTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var libraryTask: Task<Void, Never>?
    private var permissionsObserver: AnyCancellable?
    private let log = Logger(subsystem: "ai.sway.Sway", category: "app")

    init() {
        // The monitor is a separate object, so its changes have to be forwarded
        // for views observing the model alone to update.
        permissionsObserver = permissions.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        refreshLibrary()
        log.info("app model ready")
    }

    var isBusy: Bool { phase == .countdown || phase == .recording || phase == .processing }

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
        guard editor?.isExporting != true else { return }
        editor?.commitProjectName()
        editor?.save()
        log.info("record tapped")
        editor?.pause()
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
        sourceTask?.cancel()
        thumbnailTask?.cancel()
        isLoadingSources = false
        phase = editor == nil ? .idle : .editing
    }

    func reloadSources() {
        isLoadingSources = true
        sourcesError = nil
        sourceTask?.cancel()
        thumbnailTask?.cancel()
        sourceTask = Task {
            do {
                await catalog.invalidate()
                try Task.checkCancellation()
                let loaded = try await catalog.sources(
                    excludingBundleIdentifiers: [AppModel.bundleIdentifier]
                )
                try Task.checkCancellation()
                self.sources = loaded
                if self.selectedSource == nil {
                    self.selectedSourceID = loaded.first?.id
                }
                self.loadThumbnails(for: loaded)
            } catch {
                guard !Task.isCancelled else { return }
                if case CaptureSourceError.screenRecordingPermissionMissing = error {
                    self.showPermissions()
                } else {
                    self.sourcesError = "\(error)"
                }
            }
            guard !Task.isCancelled else { return }
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
                    guard !Task.isCancelled else { return }
                    self.thumbnails[source.id] = image
                }
            }
        }
    }

    // MARK: - Recording

    /// Start goes through a short countdown first, so the user has a beat to
    /// get their screen ready. The countdown floats over everything and can be
    /// cancelled; capture only starts when it finishes.
    func startRecording() {
        guard phase == .picking, selectedSource != nil else { return }
        sourceTask?.cancel()
        thumbnailTask?.cancel()
        isLoadingSources = false
        phase = .countdown
        mainWindow?.orderOut(nil)

        let panel = CountdownPanel { [weak self] in self?.cancelCountdown() }
        panel.show(count: 3)
        countdownPanel = panel

        countdownTask = Task {
            for count in stride(from: 3, through: 1, by: -1) {
                panel.update(count: count)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            panel.close()
            self.countdownPanel = nil
            self.beginSession()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownPanel?.close()
        countdownPanel = nil
        phase = .picking
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func beginSession() {
        guard let source = selectedSource else {
            phase = .picking
            return
        }
        let options = ScreenRecorderOptions(
            target: source.target,
            frameRate: recordingFrameRate,
            capturesSystemAudio: capturesSystemAudio,
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
                self.mainWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
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
                self.refreshLibrary()
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
        open(url: url)
    }

    func open(url: URL) {
        do {
            let bundle = SwayProjectBundle(url: url)
            let project = try bundle.readProject()
            let track = try bundle.readCursorTrack()
            let edit = (try? bundle.readEdit())
                ?? SwayEdit.initial(duration: project.duration, track: track)
            editor = EditorModel(
                result: RecordingResult(
                    bundle: bundle, project: project, track: track,
                    shapes: bundle.readShapes(), edit: edit
                )
            )
            phase = .editing
        } catch {
            errorMessage = "Could not open that recording.\n\n\(error)"
        }
    }

    // MARK: - Library

    /// Back to the welcome screen, which doubles as the recordings library.
    func showLibrary() {
        guard editor?.isExporting != true else { return }
        editor?.commitProjectName()
        editor?.pause()
        editor = nil
        phase = .idle
        refreshLibrary()
    }

    func refreshLibrary() {
        isLoadingLibrary = library.isEmpty
        libraryTask?.cancel()
        libraryTask = Task {
            let items = await LibraryItem.scan(directory: AppModel.recordingsDirectory)
            if Task.isCancelled { return }
            self.library = items
            self.isLoadingLibrary = false
        }
    }

    // MARK: - Helpers

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "ai.sway.Sway"

    static var recordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Sway", isDirectory: true)
    }

    static func newBundleURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return recordingsDirectory.appendingPathComponent(
            "\(formatter.string(from: Date())).\(SwayProjectBundle.pathExtension)"
        )
    }
}
