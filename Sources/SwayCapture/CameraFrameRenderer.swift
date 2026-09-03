#if os(macOS)
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwayCore

/// Applies one camera state to one frame: crop to the viewport, draw the
/// recorded cursor back in, scale to the output size, and optionally present
/// the result as a floating card on a gradient canvas.
///
/// The editor's preview and the exporter both go through here, so scrubbing the
/// timeline shows exactly what will be rendered.
public enum CameraFrameRenderer {
    public static func render(
        source: CIImage,
        camera: CameraKeyframe,
        time: TimeInterval,
        outputSize: CGSize,
        cursor: CursorRenderer?,
        canvas: CanvasStyle? = nil
    ) -> CIImage {
        guard let canvas, canvas.isEnabled else {
            return frame(source: source, camera: camera, time: time, targetSize: outputSize, cursor: cursor)
        }

        let style = canvas.clamped()
        let assets = CanvasAssets.shared.assets(for: style, outputSize: outputSize)
        let content = frame(
            source: source, camera: camera, time: time,
            targetSize: assets.contentRect.size, cursor: cursor
        )
        .cropped(to: CGRect(origin: .zero, size: assets.contentRect.size))

        let card = CIFilter.blendWithMask()
        card.inputImage = content
        card.backgroundImage = CIImage.empty()
        card.maskImage = assets.mask
        let masked = (card.outputImage ?? content)
            .transformed(by: CGAffineTransform(
                translationX: assets.contentRect.origin.x, y: assets.contentRect.origin.y
            ))

        var result = assets.background
        if let shadow = assets.shadow {
            result = shadow.composited(over: result)
        }
        return masked.composited(over: result)
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// The camera viewport of `source`, aspect-filled and scaled to
    /// `targetSize`, origin at zero.
    private static func frame(
        source: CIImage,
        camera: CameraKeyframe,
        time: TimeInterval,
        targetSize: CGSize,
        cursor: CursorRenderer?
    ) -> CIImage {
        let extent = source.extent
        let zoom = max(1, camera.zoom)

        // Camera coordinates are top-left origin; CoreImage is bottom-left.
        var cropWidth = extent.width / zoom
        var cropHeight = extent.height / zoom

        // Aspect-fill: when the output aspect differs from the capture's, the
        // viewport is narrowed on one axis (never stretched), staying centered
        // on the camera.
        let targetAspect = targetSize.width / targetSize.height
        let viewportAspect = cropWidth / cropHeight
        if abs(targetAspect - viewportAspect) > 0.001 {
            if targetAspect < viewportAspect {
                cropWidth = cropHeight * targetAspect
            } else {
                cropHeight = cropWidth / targetAspect
            }
        }

        var cropX = extent.origin.x + camera.centerX * extent.width - cropWidth / 2
        var cropY = extent.origin.y + (1 - camera.centerY) * extent.height - cropHeight / 2
        // Keep the (possibly narrowed) viewport inside the captured frame.
        cropX = min(max(cropX, extent.minX), max(extent.minX, extent.maxX - cropWidth))
        cropY = min(max(cropY, extent.minY), max(extent.minY, extent.maxY - cropHeight))
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
            .intersection(extent)
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else { return source }

        var image = source
        if let cursor {
            image = cursor.draw(on: image, fullExtent: extent, time: time)
        }
        return image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(
                scaleX: targetSize.width / cropRect.width,
                y: targetSize.height / cropRect.height
            ))
    }
}

/// The parts of the canvas look that do not change frame to frame - the
/// gradient, the card's shadow and its rounded mask - built once per
/// (style, output size) and reused. Preview and export render at different
/// sizes concurrently, so the cache is locked and keeps a few entries.
final class CanvasAssets: @unchecked Sendable {
    struct Assets {
        let contentRect: CGRect
        let background: CIImage
        let shadow: CIImage?
        let mask: CIImage
    }

    private struct Key: Hashable {
        let style: CanvasStyle
        let width: Int
        let height: Int
    }

    static let shared = CanvasAssets()
    private let lock = NSLock()
    private var cache: [Key: Assets] = [:]
    private var order: [Key] = []
    /// Used once per cache entry to bake the blurred gradient and shadow into
    /// bitmaps. Without this they would be re-evaluated (blur included) on
    /// every frame, since a CIImage is a recipe, not pixels.
    private let bakeContext = CIContext(options: [.cacheIntermediates: false])

    func assets(for style: CanvasStyle, outputSize: CGSize) -> Assets {
        let key = Key(style: style, width: Int(outputSize.width), height: Int(outputSize.height))
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = build(style: style, outputSize: outputSize)
        lock.lock()
        cache[key] = built
        order.append(key)
        if order.count > 6 {
            cache.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return built
    }

    private func build(style: CanvasStyle, outputSize: CGSize) -> Assets {
        let shorter = min(outputSize.width, outputSize.height)
        let padding = (shorter * style.padding).rounded()
        let contentRect = CGRect(
            x: padding,
            y: padding,
            width: max(2, (outputSize.width - padding * 2).rounded()),
            height: max(2, (outputSize.height - padding * 2).rounded())
        )
        let radius = min(contentRect.width, contentRect.height) * style.cornerRadius

        let mask = CanvasAssets.roundedRect(size: contentRect.size, radius: radius, color: .white)
            ?? CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: contentRect.size))

        var shadow: CIImage?
        if style.shadow > 0.01 {
            let blurRadius = shorter * 0.03
            let offsetY = -shorter * 0.015
            let shape = CanvasAssets.roundedRect(
                size: contentRect.size, radius: radius,
                color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.85 * style.shadow)
            )
            shadow = shape?
                .transformed(by: CGAffineTransform(
                    translationX: contentRect.origin.x, y: contentRect.origin.y + offsetY
                ))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: blurRadius)
                .cropped(to: CGRect(origin: .zero, size: outputSize))
        }

        return Assets(
            contentRect: contentRect,
            background: baked(CanvasAssets.gradient(style.background, size: outputSize), size: outputSize),
            shadow: shadow.map { baked($0, size: outputSize) },
            mask: mask
        )
    }

    /// Renders a recipe to pixels once so per-frame compositing is a plain
    /// texture blend.
    private func baked(_ image: CIImage, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        guard let cgImage = bakeContext.createCGImage(image, from: rect) else { return image }
        return CIImage(cgImage: cgImage)
    }

    /// Large soft color blobs over a base color, blurred into one another.
    private static func gradient(_ background: CanvasStyle.Background, size: CGSize) -> CIImage {
        let colors = background.colors
        let canvas = CGRect(origin: .zero, size: size)
        let base = colors.first ?? (0.1, 0.1, 0.12)
        var image = CIImage(color: CIColor(red: base.0, green: base.1, blue: base.2)).cropped(to: canvas)

        // Blob placement is deterministic so every frame (and every export)
        // gets the same canvas.
        let anchors: [(x: Double, y: Double, r: Double)] = [
            (0.15, 0.80, 0.55), (0.85, 0.20, 0.60), (0.75, 0.85, 0.45),
            (0.20, 0.15, 0.50), (0.55, 0.50, 0.40)
        ]
        for (index, color) in colors.dropFirst().enumerated() {
            let anchor = anchors[index % anchors.count]
            let radial = CIFilter.radialGradient()
            radial.center = CGPoint(x: anchor.x * size.width, y: anchor.y * size.height)
            radial.radius0 = 0
            radial.radius1 = Float(anchor.r * max(size.width, size.height))
            radial.color0 = CIColor(red: color.0, green: color.1, blue: color.2, alpha: 0.85)
            radial.color1 = CIColor(red: color.0, green: color.1, blue: color.2, alpha: 0)
            if let blob = radial.outputImage?.cropped(to: canvas) {
                image = blob.composited(over: image)
            }
        }
        return image
            .clampedToExtent()
            .applyingGaussianBlur(sigma: min(size.width, size.height) * 0.06)
            .cropped(to: canvas)
    }

    private static func roundedRect(size: CGSize, radius: CGFloat, color: CGColor) -> CIImage? {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        let path = CGPath(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerWidth: min(radius, size.width / 2),
            cornerHeight: min(radius, size.height / 2),
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
#endif
