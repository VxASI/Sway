import Foundation

/// The "clean" presentation: the recording floats as a rounded card with a
/// soft shadow over a full-canvas gradient, instead of filling the frame.
/// Shared by preview and export; every value is relative to the output size
/// so the look is identical at any resolution or aspect ratio.
public struct CanvasStyle: Codable, Hashable, Sendable {
    public enum Background: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Teal, orange, yellow, purple and magenta blobs.
        case spectrum
        /// Teal into deep purple and magenta.
        case aurora
        /// Orange, yellow and pink.
        case sunset
        /// Blues and teals.
        case ocean
        /// Near-black greys.
        case graphite

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .spectrum: return "Spectrum"
            case .aurora: return "Aurora"
            case .sunset: return "Sunset"
            case .ocean: return "Ocean"
            case .graphite: return "Graphite"
            }
        }

        /// Palette as (r, g, b) in 0...1. The first color is the base; the
        /// rest become soft blobs placed around the canvas.
        public var colors: [(Double, Double, Double)] {
            switch self {
            case .spectrum:
                return [(0.09, 0.45, 0.50), (0.98, 0.55, 0.20), (0.99, 0.82, 0.25),
                        (0.45, 0.25, 0.75), (0.90, 0.20, 0.60)]
            case .aurora:
                return [(0.10, 0.50, 0.55), (0.30, 0.15, 0.60), (0.85, 0.20, 0.65), (0.10, 0.75, 0.70)]
            case .sunset:
                return [(0.95, 0.45, 0.20), (0.99, 0.80, 0.30), (0.95, 0.35, 0.55), (0.55, 0.20, 0.45)]
            case .ocean:
                return [(0.08, 0.30, 0.60), (0.10, 0.65, 0.75), (0.25, 0.40, 0.90), (0.05, 0.20, 0.40)]
            case .graphite:
                return [(0.11, 0.11, 0.13), (0.20, 0.20, 0.24), (0.07, 0.07, 0.09)]
            }
        }
    }

    public var isEnabled: Bool
    /// Margin around the recording, as a fraction of the output's shorter
    /// side (0.06 = 6%).
    public var padding: Double
    /// Corner radius as a fraction of the recording's shorter side.
    public var cornerRadius: Double
    /// Shadow strength, 0 (none) to 1.
    public var shadow: Double
    public var background: Background

    public init(
        isEnabled: Bool = false,
        padding: Double = 0.07,
        cornerRadius: Double = 0.025,
        shadow: Double = 0.6,
        background: Background = .spectrum
    ) {
        self.isEnabled = isEnabled
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.background = background
    }

    public static let off = CanvasStyle(isEnabled: false)
    public static let clean = CanvasStyle(isEnabled: true)

    public func clamped() -> CanvasStyle {
        var style = self
        style.padding = clamp(style.padding, 0, 0.25)
        style.cornerRadius = clamp(style.cornerRadius, 0, 0.12)
        style.shadow = clamp(style.shadow, 0, 1)
        return style
    }
}
