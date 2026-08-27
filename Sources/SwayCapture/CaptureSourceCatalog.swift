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

    public var description: String {
        switch self {
        case .screenRecordingPermissionMissing:
            return "Screen Recording permission has not been granted to Sway."
        case .timedOut:
            return "ScreenCaptureKit did not answer in time."
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
        // Without this check `SCShareableContent` can sit there for a long time
        // instead of failing, which looks like a hung picker.
        guard CapturePermissions.hasScreenRecording else {
            throw CaptureSourceError.screenRecordingPermissionMissing
        }

        let content = try await shareableContent()
        let displayIDs = content.displays.map(\.displayID)
        let names = await MainActor.run { CaptureSourceCatalog.displayNames(for: displayIDs) }
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
        log.info("listed \(sources.count, privacy: .public) capture sources")
        return sources
    }

    /// A preview image for one source. Returns `nil` rather than throwing: a
    /// missing thumbnail must never stop the user from picking something.
    public func thumbnail(for target: CaptureTarget, maximumWidth: Int = 480) async -> CGImage? {
        guard CapturePermissions.hasScreenRecording else { return nil }
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

    private let log = Logger(subsystem: "ai.sway.Sway", category: "capture-sources")

    private func shareableContent() async throws -> SCShareableContent {
        if let content { return content }
        log.info("fetching shareable content")
        let fetched = try await CaptureSourceCatalog.withTimeout(seconds: 10) {
            try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
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
