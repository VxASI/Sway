import AppKit
import SwiftUI

/// Small always-on-top control shown while recording: elapsed time and Stop.
/// It is a non-activating panel so clicking Stop does not pull the recorded app
/// out of focus, and Sway is excluded from the capture so it never shows up in
/// the recording.
@MainActor
final class RecordingControlPanel {
    private let state = RecordingControlState()
    private let panel: NSPanel

    init(onStop: @escaping () -> Void) {
        let state = self.state
        let hosting = NSHostingView(rootView: RecordingControlView(state: state, onStop: onStop))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 196, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 48)
            )
        }
        panel.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval) {
        state.elapsed = elapsed
    }

    func close() {
        panel.orderOut(nil)
    }
}

@MainActor
final class RecordingControlState: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

private struct RecordingControlView: View {
    @ObservedObject var state: RecordingControlState
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
            Button(action: onStop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop recording (⇧⌘S)")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var label: String {
        let total = Int(state.elapsed.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// ⇧⌘S anywhere on the system stops the recording, so the user never has to go
/// looking for Sway's window.
@MainActor
final class StopHotKey {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(action: @escaping () -> Void) {
        let matches: (NSEvent) -> Bool = { event in
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
                && event.charactersIgnoringModifiers?.lowercased() == "s"
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard matches(event) else { return }
            Task { @MainActor in action() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard matches(event) else { return event }
            Task { @MainActor in action() }
            return nil
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
