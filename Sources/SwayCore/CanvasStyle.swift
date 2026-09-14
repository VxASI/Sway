import CoreGraphics
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
        /// An image the user imported; see `customImage`. Falls back to
        /// graphite until one is set.
        case custom

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .spectrum: return "Spectrum"
            case .aurora: return "Aurora"
            case .sunset: return "Sunset"
            case .ocean: return "Ocean"
            case .graphite: return "Graphite"
            case .custom: return "Custom image…"
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
            case .graphite, .custom:
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
    /// File name of the imported background inside the bundle's `canvas/`
    /// directory, when `background == .custom`.
    public var customImage: String?
    /// Softening applied to a custom image, 0 (sharp) to 1 (very soft).
    public var customBlur: Double

    public init(
        isEnabled: Bool = false,
        padding: Double = 0.07,
        cornerRadius: Double = 0.025,
        shadow: Double = 0.6,
        background: Background = .spectrum,
        customImage: String? = nil,
        customBlur: Double = 0.3
    ) {
        self.isEnabled = isEnabled
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.background = background
        self.customImage = customImage
        self.customBlur = customBlur
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, padding, cornerRadius, shadow, background, customImage, customBlur
    }

    /// Tolerant decoding so edits from older builds still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CanvasStyle()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? d.shadow
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? d.background
        customImage = try c.decodeIfPresent(String.self, forKey: .customImage)
        customBlur = try c.decodeIfPresent(Double.self, forKey: .customBlur) ?? d.customBlur
    }

    /// Where the recording sits on a canvas of `outputSize`: the largest rect
    /// with the recording's own aspect ratio that fits inside the padding,
    /// centered. Keeping the source aspect is what guarantees the whole
    /// recording is visible at 1x - an inset rect with a slightly different
    /// aspect would have to crop the top and bottom to fill itself.
    /// Coordinates are origin-agnostic (the rect is symmetric).
    public func contentRect(in outputSize: CGSize, contentAspect: Double) -> CGRect {
        let shorter = min(outputSize.width, outputSize.height)
        let inset = (shorter * clamp(padding, 0, 0.25)).rounded()
        let availableWidth = max(2, outputSize.width - inset * 2)
        let availableHeight = max(2, outputSize.height - inset * 2)
        let aspect = contentAspect > 0 ? contentAspect : availableWidth / availableHeight
        var width = availableWidth
        var height = (width / aspect).rounded()
        if height > availableHeight {
            height = availableHeight
            width = (height * aspect).rounded()
        }
        return CGRect(
            x: ((outputSize.width - width) / 2).rounded(),
            y: ((outputSize.height - height) / 2).rounded(),
            width: max(2, width),
            height: max(2, height)
        )
    }

    public static let off = CanvasStyle(isEnabled: false)
    public static let clean = CanvasStyle(isEnabled: true)

    public func clamped() -> CanvasStyle {
        var style = self
        style.padding = clamp(style.padding, 0, 0.25)
        style.cornerRadius = clamp(style.cornerRadius, 0, 0.12)
        style.shadow = clamp(style.shadow, 0, 1)
        style.customBlur = clamp(style.customBlur, 0, 1)
        return style
    }
}
