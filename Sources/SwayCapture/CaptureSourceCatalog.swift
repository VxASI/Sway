#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One thing the user can pick in the capture picker: a whole display or a
/// single window, with the thumbnail and the name shown next to it.
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
    public let thumbnail: CGImage?
    public let width: Int
    public let height: Int

    public var aspectRatio: Double {
        height > 0 ? Double(width) / Double(height) : 16.0 / 9
    }
}

/// Lists what can be captured right now, with thumbnails, excluding Sway's own
/// windows so the picker never offers to record itself.
public enum CaptureSourceCatalog {
    public static func load(excludingBundleIdentifiers excluded: [String] = []) async throws -> [CaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )

        var sources: [CaptureSource] = []
        for display in content.displays {
            let bounds = CGDisplayBounds(display.displayID)
            sources.append(
                CaptureSource(
                    id: "display-\(display.displayID)",
                    kind: .display,
                    target: .display(display.displayID),
                    name: displayName(for: display.displayID),
                    subtitle: "\(display.width) x \(display.height)",
                    thumbnail: await thumbnail(
                        filter: SCContentFilter(display: display, excludingWindows: []),
                        width: display.width,
                        height: display.height,
                        legacy: { CGDisplayCreateImage(display.displayID) }
                    ),
                    width: display.width,
                    height: display.height
                )
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

        for window in windows {
            sources.append(
                CaptureSource(
                    id: "window-\(window.windowID)",
                    kind: .window,
                    target: .window(window.windowID),
                    name: window.title ?? window.owningApplication?.applicationName ?? "Window",
                    subtitle: window.owningApplication?.applicationName ?? "",
                    thumbnail: await thumbnail(
                        filter: SCContentFilter(desktopIndependentWindow: window),
                        width: Int(window.frame.width),
                        height: Int(window.frame.height),
                        legacy: {
                            CGWindowListCreateImage(
                                .null,
                                .optionIncludingWindow,
                                window.windowID,
                                [.boundsIgnoreFraming, .bestResolution]
                            )
                        }
                    ),
                    width: Int(window.frame.width),
                    height: Int(window.frame.height)
                )
            )
        }
        return sources
    }

    /// The name macOS shows for a display ("Built-in Display", "LG Monitor").
    public static func displayName(for displayID: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
        if let name = screen?.localizedName, !name.isEmpty {
            return name
        }
        return CGDisplayIsBuiltin(displayID) != 0 ? "Built-in Display" : "Display \(displayID)"
    }

    private static func thumbnail(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        legacy: () -> CGImage?
    ) async -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(1, 480 / Double(width))
        configuration.width = max(2, Int(Double(width) * scale))
        configuration.height = max(2, Int(Double(height) * scale))
        configuration.showsCursor = false
        if #available(macOS 14.0, *) {
            return try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        }
        // macOS 13 has no screenshot API in ScreenCaptureKit.
        return legacy()
    }
}
#endif
