#if os(macOS)
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwayCore

/// Draws the cursor and click feedback into a frame, in source pixel space.
/// Shared by the exporter and the editor's live preview, so what the user sees
/// while scrubbing is what gets rendered.
///
/// Everything here is derived from the recorded event stream and the
/// `CursorStyle`, so all of it can change after the recording is done: the
/// path is smoothed, the size is chosen, the shape is the one the system
/// showed (or Sway's arrow), and the cursor fades out when idle or while
/// typing. Expensive pieces are prepared once in `init`; per frame it is a few
/// binary searches and image transforms.
public struct CursorRenderer {
    public let style: CursorStyle
    let scale: Double

    /// The path actually drawn: the recorded track, exponentially smoothed by
    /// `style.smoothing` and resampled so lookups are cheap.
    private let path: CursorTrack
    private let clickTimes: [TimeInterval]
    /// Times at which the pointer was moving, for the idle fade.
    private let movementTimes: [TimeInterval]
    private let keyTimes: [TimeInterval]
    private let shapes: CursorShapeTrack
    /// Pointer images by shape ID, at the origin, already scaled to source
    /// pixels at the chosen size.
    private let shapeImages: [String: (image: CIImage, hotspot: CGPoint)]
    /// Sway's arrow, rasterized once at the origin.
    private let arrow: CIImage?
    private let arrowSize: Double

    static let clickRingDuration: TimeInterval = 0.45
    static let fadeDuration: TimeInterval = 0.3
    /// How long after the last key press the cursor stays hidden.
    static let typingHold: TimeInterval = 0.9

    public init(
        style: CursorStyle,
        track: CursorTrack,
        shapes: CursorShapeTrack = CursorShapeTrack(),
        shapeImages: [String: CGImage] = [:],
        scale: Double
    ) {
        let style = style.clamped()
        self.style = style
        self.scale = scale
        self.shapes = shapes
        self.clickTimes = track.events.filter { $0.type.isClickDown }.map(\.time)
        self.keyTimes = track.events.filter { $0.type == .keyDown }.map(\.time)
        self.movementTimes = CursorRenderer.movementTimes(in: track)
        self.path = CursorRenderer.smoothedPath(track, timeConstant: style.smoothingTimeConstant)

        let sizeFactor = scale * style.size
        arrowSize = 24.0 * sizeFactor
        arrow = CursorRenderer.rasterizeArrow(size: arrowSize)

        var images: [String: (CIImage, CGPoint)] = [:]
        for shape in shapes.shapes {
            guard let cgImage = shapeImages[shape.id], cgImage.width > 0, cgImage.height > 0 else { continue }
            // Image pixels may be 2x the point size; scale to points, then to
            // source pixels at the chosen size.
            let targetWidth = shape.width * sizeFactor
            let targetHeight = shape.height * sizeFactor
            let image = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(
                scaleX: targetWidth / Double(cgImage.width),
                y: targetHeight / Double(cgImage.height)
            ))
            images[shape.id] = (image, CGPoint(x: shape.hotspotX * sizeFactor, y: shape.hotspotY * sizeFactor))
        }
        self.shapeImages = images
    }

    /// Cursor coordinates are normalized to the whole capture, so the overlay
    /// is placed in full-frame pixel space and the caller crops afterwards.
    public func draw(on image: CIImage, fullExtent: CGRect, time: TimeInterval) -> CIImage {
        guard style.isVisible, let position = path.position(at: time) else { return image }
        let alpha = visibility(at: time)
        guard alpha > 0.001 else { return image }

        // CoreImage's origin is bottom-left; the track's is top-left.
        let center = CGPoint(
            x: fullExtent.origin.x + position.x * fullExtent.width,
            y: fullExtent.origin.y + (1 - position.y) * fullExtent.height
        )

        var base = image
        if style.spotlight {
            base = spotlight(on: base, fullExtent: fullExtent, center: center, alpha: alpha)
        }

        var overlay: CIImage?
        if style.clickRings, let ring = ringImage(at: time, center: center) {
            overlay = ring
        }
        if let pointer = pointerImage(at: time, center: center) {
            overlay = overlay.map { pointer.composited(over: $0) } ?? pointer
        }
        guard var result = overlay else { return base }
        if alpha < 0.999 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
            ])
        }
        return result.composited(over: base)
    }

    // MARK: - Visibility

    /// 1 when the cursor is shown, easing to 0 when hidden for idling or typing.
    func visibility(at time: TimeInterval) -> Double {
        var alpha = 1.0
        if style.hideWhenIdle, let lastMove = CursorRenderer.last(in: movementTimes, atOrBefore: time) {
            let idle = time - lastMove - style.idleSeconds
            if idle > 0 { alpha = min(alpha, 1 - CursorRenderer.smoothstep(idle / CursorRenderer.fadeDuration)) }
        }
        if style.hideWhileTyping, let lastKey = CursorRenderer.last(in: keyTimes, atOrBefore: time) {
            let since = time - lastKey
            if since < CursorRenderer.typingHold {
                // Fade out quickly on the key press, hold, then fade back in.
                let out = CursorRenderer.smoothstep(since / 0.12)
                let back = CursorRenderer.smoothstep(
                    (since - (CursorRenderer.typingHold - CursorRenderer.fadeDuration)) / CursorRenderer.fadeDuration
                )
                alpha = min(alpha, 1 - out + back)
            }
        }
        return max(0, min(1, alpha))
    }

    // MARK: - Layers

    private func pointerImage(at time: TimeInterval, center: CGPoint) -> CIImage? {
        if style.shape == .recorded,
           let shape = shapes.shape(at: time),
           let entry = shapeImages[shape.id] {
            let height = entry.image.extent.height
            return entry.image.transformed(by: CGAffineTransform(
                translationX: center.x - entry.hotspot.x,
                y: center.y + entry.hotspot.y - height
            ))
        }
        let padding = arrowSize * 0.2
        let height = arrowSize + padding * 2
        // Places the tip exactly on the recorded cursor position.
        return arrow?.transformed(by: CGAffineTransform(
            translationX: center.x - padding,
            y: center.y - height + padding
        ))
    }

    private func ringImage(at time: TimeInterval, center: CGPoint) -> CIImage? {
        guard let click = clickTimes.last(where: { $0 <= time && time - $0 <= CursorRenderer.clickRingDuration })
        else { return nil }
        let progress = (time - click) / CursorRenderer.clickRingDuration
        let radius = arrowSize * (0.6 + 1.4 * progress)
        let alpha = 1 - progress
        let rgb = style.ringColor.rgb
        return CursorRenderer.drawing(
            size: CGSize(width: radius * 2 + 8, height: radius * 2 + 8),
            origin: CGPoint(x: center.x - radius - 4, y: center.y - radius - 4)
        ) { context in
            context.setStrokeColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha))
            context.setLineWidth(max(2, arrowSize * 0.08))
            context.strokeEllipse(in: CGRect(x: 4, y: 4, width: radius * 2, height: radius * 2))
        }
    }

    /// Darkens the frame except for a soft circle around the cursor.
    private func spotlight(on image: CIImage, fullExtent: CGRect, center: CGPoint, alpha: Double) -> CIImage {
        let radius = min(fullExtent.width, fullExtent.height) * 0.22
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(radius * 0.55)
        gradient.radius1 = Float(radius)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * alpha)
        guard let shade = gradient.outputImage?.cropped(to: fullExtent) else { return image }
        return shade.composited(over: image)
    }

    // MARK: - Preparation

    /// The recorded path smoothed and resampled at 120 Hz. Clicks and key
    /// presses are not positions, so they are excluded from the geometry.
    private static func smoothedPath(_ track: CursorTrack, timeConstant: TimeInterval) -> CursorTrack {
        let positional = CursorTrack(events: track.events.filter { $0.type != .keyDown })
        guard timeConstant > 0, positional.events.count > 1 else { return positional }
        let samples = CursorPathSmoother(timeConstant: timeConstant)
            .smooth(positional.resampled(hz: 120))
        return CursorTrack(events: samples.map {
            CursorEvent(time: $0.time, x: $0.x, y: $0.y, type: .sample)
        })
    }

    private static func movementTimes(in track: CursorTrack) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var last: CursorEvent?
        for event in track.events where event.type != .keyDown {
            if let previous = last, abs(event.x - previous.x) < 0.0005, abs(event.y - previous.y) < 0.0005,
               !event.type.isClickDown, !event.type.isDrag, event.type != .scrollWheel {
                continue
            }
            times.append(event.time)
            last = event
        }
        return times
    }

    private static func last(in sorted: [TimeInterval], atOrBefore time: TimeInterval) -> TimeInterval? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? sorted[low - 1] : nil
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }

    private static func rasterizeArrow(size: Double) -> CIImage? {
        // Arrow outline in a unit box with the hotspot (the tip) at (0, 0) and
        // y growing downwards, the way a cursor is normally described.
        let points: [CGPoint] = [
            CGPoint(x: 0.00, y: 0.00), CGPoint(x: 0.00, y: 0.78), CGPoint(x: 0.22, y: 0.60),
            CGPoint(x: 0.36, y: 0.95), CGPoint(x: 0.52, y: 0.88), CGPoint(x: 0.38, y: 0.54),
            CGPoint(x: 0.64, y: 0.54)
        ]
        let padding = size * 0.2
        let height = size + padding * 2
        return drawing(size: CGSize(width: size + padding * 2, height: height), origin: .zero) { context in
            context.setShadow(offset: CGSize(width: 0, height: -size * 0.05), blur: size * 0.12)
            let path = CGMutablePath()
            for (index, point) in points.enumerated() {
                let converted = CGPoint(
                    x: padding + point.x * size,
                    y: height - padding - point.y * size
                )
                if index == 0 { path.move(to: converted) } else { path.addLine(to: converted) }
            }
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.setLineWidth(max(1, size * 0.05))
            context.strokePath()
        }
    }

    private static func drawing(
        size: CGSize,
        origin: CGPoint,
        _ body: (CGContext) -> Void
    ) -> CIImage? {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        body(context)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// Loads the pointer PNGs a bundle recorded, keyed by shape ID.
    public static func loadShapeImages(for shapes: CursorShapeTrack, in bundle: SwayProjectBundle) -> [String: CGImage] {
        var images: [String: CGImage] = [:]
        for shape in shapes.shapes {
            let url = bundle.cursorsDirectoryURL.appendingPathComponent(shape.fileName)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            images[shape.id] = image
        }
        return images
    }
}
#endif
