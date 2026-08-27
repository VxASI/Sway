#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// One thing the user can pick in the capture picker: a whole display or a
/// single window, with the name shown next to it. Thumbnails are fetched
/// separately, since a screenshot per window is far slower than listing them.
public struct CaptureSource: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case display
        case window
    }

    public let id: String
    public let kind: Kind
    public let target: CaptureTarget
    /// "Built-in Display", "LG Monitor", or a window title.
    public let name: String
    /// Owning application for windows, resolution for displays.
    public let subtitle: String
    public let width: Int
    public let height: Int

    public var aspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 16.0 / 9
    }
}

public enum CaptureSourceError: Error, CustomStringConvertible {
    case screenRecordingPermissionMissing
    case timedOut
    case failed(String)

    public var description: String {
        switch self {
        case .screenRecordingPermissionMissing:
            return """
            Sway does not have Screen Recording permission yet. If you just \
            granted it, quit and reopen Sway - macOS only applies the grant to \
            a fresh launch.
            """
        case .timedOut:
            return """
            ScreenCaptureKit stopped responding. This is usually a stuck screen \
            recording daemon: run `killall -9 replayd` in Terminal, then try \
            again.
            """
        case let .failed(message):
            return message
        }
    }
}

/// Lists what can be captured right now, excluding Sway's own windows so the
/// picker never offers to record itself.
///
/// An actor rather than free functions because the picker asks for thumbnails
/// one tile at a time and they all need the same `SCShareableContent`.
public actor CaptureSourceCatalog {
    private var content: SCShareableContent?

    public init() {}

    /// Lists displays and windows. Fast: no screenshots are taken here.
    public func sources(excludingBundleIdentifiers excluded: [String] = []) async throws -> [CaptureSource] {
        let content = try await shareableContent()
        let displayIDs = content.displays.map(\.displayID)
        // Bounded, because the name lookup needs the main actor and a busy main
        // actor must cost us the pretty names, not the whole list.
        let names = (try? await CaptureSourceCatalog.withTimeout(seconds: 3) {
            await MainActor.run { CaptureSourceCatalog.displayNames(for: displayIDs) }
        }) ?? [:]
        var sources = content.displays.map { display in
            CaptureSource(
                id: "display-\(display.displayID)",
                kind: .display,
                target: .display(display.displayID),
                name: names[display.displayID] ?? "Display \(display.displayID)",
                subtitle: "\(display.width) x \(display.height)",
                width: display.width,
                height: display.height
            )
        }

        let windows = content.windows
            .filter { window in
                guard let app = window.owningApplication else { return false }
                guard !excluded.contains(app.bundleIdentifier) else { return false }
                // Menu bar items, shadows and other chrome show up as tiny
                // untitled windows; they are not useful capture targets.
                return window.frame.width >= 160 && window.frame.height >= 120
                    && !(window.title ?? "").isEmpty
            }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }

        sources += windows.map { window in
            CaptureSource(
                id: "window-\(window.windowID)",
                kind: .window,
                target: .window(window.windowID),
                name: window.title ?? window.owningApplication?.applicationName ?? "Window",
                subtitle: window.owningApplication?.applicationName ?? "",
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            )
        }
        Self.log.info("listed \(sources.count, privacy: .public) capture sources")
        return sources
    }

    /// A preview image for one source. Returns `nil` rather than throwing: a
    /// missing thumbnail must never stop the user from picking something.
    public func thumbnail(for target: CaptureTarget, maximumWidth: Int = 480) async -> CGImage? {
        guard let content = try? await shareableContent() else { return nil }

        switch target {
        case let .display(displayID):
            guard let display = content.displays.first(where: {
                displayID == nil || $0.displayID == displayID
            }) else { return nil }
            return await image(
                filter: SCContentFilter(display: display, excludingWindows: []),
                width: display.width,
                height: display.height,
                maximumWidth: maximumWidth,
                legacy: { CGDisplayCreateImage(display.displayID) }
            )
        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            return await image(
                filter: SCContentFilter(desktopIndependentWindow: window),
                width: Int(window.frame.width),
                height: Int(window.frame.height),
                maximumWidth: maximumWidth,
                legacy: {
                    CGWindowListCreateImage(
                        .null,
                        .optionIncludingWindow,
                        windowID,
                        [.boundsIgnoreFraming, .bestResolution]
                    )
                }
            )
        }
    }

    /// Drops the cached window list so the next call sees the current desktop.
    public func invalidate() {
        content = nil
    }

    /// The names macOS shows for displays ("Built-in Display", "LG Monitor").
    /// Main actor because `NSScreen` is AppKit, which must not be touched from
    /// the actor's background executor.
    @MainActor
    public static func displayNames(
        for displayIDs: [CGDirectDisplayID]
    ) -> [CGDirectDisplayID: String] {
        let screens = NSScreen.screens
        return displayIDs.reduce(into: [:]) { result, displayID in
            let screen = screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == displayID
            }
            if let name = screen?.localizedName, !name.isEmpty {
                result[displayID] = name
            } else {
                result[displayID] = CGDisplayIsBuiltin(displayID) != 0
                    ? "Built-in Display"
                    : "Display \(displayID)"
            }
        }
    }

    private static let log = Logger(subsystem: "ai.sway.Sway", category: "capture-sources")

    private func shareableContent() async throws -> SCShareableContent {
        if let content { return content }
        Self.log.info("fetching shareable content")
        let fetched = try await CaptureSourceCatalog.shareableContentWithDeadline(seconds: 8)
        content = fetched
        return fetched
    }

    private func image(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        maximumWidth: Int,
        legacy: @Sendable @escaping () -> CGImage?
    ) async -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(1, Double(maximumWidth) / Double(width))
        configuration.width = max(2, Int(Double(width) * scale))
        configuration.height = max(2, Int(Double(height) * scale))
        configuration.showsCursor = false
        if #available(macOS 14.0, *) {
            return try? await CaptureSourceCatalog.withTimeout(seconds: 5) {
                try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
        }
        // macOS 13 has no screenshot API in ScreenCaptureKit.
        return legacy()
    }

    /// The completion-handler form of the shareable content call, with a hard
    /// deadline.
    ///
    /// The `async` form of this API is known to never return when the app's
    /// Screen Recording grant is half-applied (typically: granted during this
    /// launch) or when `replayd` is wedged. Since a hung continuation cannot be
    /// cancelled, the deadline lives outside it: whichever of the callback and
    /// the timer fires first wins, and the UI always gets an answer.
    private static func shareableContentWithDeadline(
        seconds: Double
    ) async throws -> SCShareableContent {
        let result: Result<SCShareableContent, Error>? = await withCheckedContinuation {
            continuation in
            let once = ResumeOnce()
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ) { content, error in
                guard once.claim() else { return }
                if let content {
                    continuation.resume(returning: .success(content))
                } else {
                    continuation.resume(
                        returning: .failure(error ?? CaptureSourceError.timedOut)
                    )
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard once.claim() else { return }
                continuation.resume(returning: nil)
            }
        }

        switch result {
        case .none:
            throw CaptureSourceError.timedOut
        case let .success(content):
            return content
        case let .failure(error):
            let code = (error as NSError).code
            log.error("shareable content failed (\(code, privacy: .public)): \(error, privacy: .public)")
            // SCStreamError.userDeclined
            if code == -3801 {
                throw CaptureSourceError.screenRecordingPermissionMissing
            }
            throw CaptureSourceError.failed(
                "ScreenCaptureKit could not list what can be recorded.\n\n\(error.localizedDescription)"
            )
        }
    }

    /// Guards a continuation that two callers race to resume.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// ScreenCaptureKit calls can stall (a pending or half-granted TCC prompt,
    /// a wedged window server). Everything user-facing goes through here so the
    /// UI gets an error instead of a spinner that never stops.
    static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CaptureSourceError.timedOut
            }
            guard let result = try await group.next() else { throw CaptureSourceError.timedOut }
            group.cancelAll()
            return result
        }
    }
}
#endif
