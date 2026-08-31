#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import SwayCore

/// Applies one camera state to one frame: crop to the viewport, draw the
/// recorded cursor back in, and scale up to the output size.
///
/// The editor's preview and the exporter both go through here, so scrubbing the
/// timeline shows exactly what will be rendered.
public enum CameraFrameRenderer {
    public static func render(
        source: CIImage,
        camera: CameraKeyframe,
        time: TimeInterval,
        outputSize: CGSize,
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
        let targetAspect = outputSize.width / outputSize.height
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
                scaleX: outputSize.width / cropRect.width,
                y: outputSize.height / cropRect.height
            ))
    }
}
#endif
