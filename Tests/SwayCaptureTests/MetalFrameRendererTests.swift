#if os(macOS)
import AppKit
import CoreImage
import IOSurface
import Metal
import MetalKit
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import SwayCapture

final class MetalFrameRendererTests: XCTestCase {
    func testSurfaceBackedTextureMatchesOffscreenOrientation() throws {
        guard let renderer = MetalFrameRenderer() else { throw XCTSkip("no Metal device") }
        let size = 64
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: size, .height: size, .bytesPerElement: 4, .bytesPerRow: size * 4,
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead, .renderTarget]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0))
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: size / 2, width: size, height: size / 2))
        let image = green.composited(over: red)
        let offscreen = try XCTUnwrap(renderer.makeTexture(from: image, width: size, height: size))
        let commandBuffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.render(image, to: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        var surfacePixels = [UInt8](repeating: 0, count: size * size * 4)
        var offscreenPixels = surfacePixels
        texture.getBytes(&surfacePixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        offscreen.getBytes(&offscreenPixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        XCTAssertTrue(surfacePixels == offscreenPixels, "surface-backed and offscreen textures must have identical row order")
        XCTAssertGreaterThan(surfacePixels[1], 200, "top row must be green")
        XCTAssertGreaterThan(surfacePixels[((size - 1) * size) * 4 + 2], 200, "bottom row must be red")
    }

    @MainActor
    func testPresentedDrawableMatchesExportOrientation() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("requires window capture on macOS 14") }
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("requires screen capture permission") }
        let renderer = try XCTUnwrap(MetalFrameRenderer())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MetalHost(view: view))
        window.center()
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let drawable = try XCTUnwrap(view.currentDrawable)
        let width = drawable.texture.width, height = drawable.texture.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        let image = green.composited(over: red)
        let commandBuffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        try renderer.render(image, to: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(commandBuffer.status, .completed)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let capturedWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let screenshot = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: capturedWindow), configuration: configuration
        )
        let displayed = NSBitmapImageRep(cgImage: screenshot)
        let expected = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.context.createCGImage(image, from: bounds)))
        for fraction in [0.25, 0.75] {
            let actualColor = try XCTUnwrap(displayed.colorAt(x: width / 2, y: Int(Double(height) * fraction))?.usingColorSpace(.deviceRGB))
            let expectedColor = try XCTUnwrap(expected.colorAt(x: width / 2, y: Int(Double(height) * fraction))?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.1, "red at y=\(fraction)")
            XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.1, "green at y=\(fraction)")
        }
    }

    private struct MetalHost: NSViewRepresentable {
        let view: MTKView
        func makeNSView(context: Context) -> MTKView { view }
        func updateNSView(_ nsView: MTKView, context: Context) {}
    }

    /// The preview draws CoreImage output into an MTKView drawable. CoreImage
    /// is bottom-left origin and Metal textures are top-left, so this pins
    /// down that a pixel in the image's top-left corner ends up in the
    /// texture's top-left corner - the thing a flipped preview would break.
    func testTopLeftOfImageLandsInTopLeftOfTexture() throws {
        guard let renderer = MetalFrameRenderer() else {
            throw XCTSkip("no Metal device")
        }
        let size = 64
        // Red everywhere, except a green square in the image's top-left (in
        // CoreImage terms: high y).
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: size / 2, width: size / 2, height: size / 2))
        let image = green.composited(over: red)

        let texture = try XCTUnwrap(renderer.makeTexture(from: image, width: size, height: size))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(
            &pixels,
            bytesPerRow: size * 4,
            from: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0
        )
        func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * size + x) * 4
            return (pixels[index], pixels[index + 1], pixels[index + 2])
        }
        // Texture row 0 is the top. BGRA layout.
        let topLeft = pixel(x: 4, y: 4)
        let bottomRight = pixel(x: size - 4, y: size - 4)
        XCTAssertGreaterThan(topLeft.g, 200, "top-left should be green: \(topLeft)")
        XCTAssertLessThan(topLeft.r, 50)
        XCTAssertGreaterThan(bottomRight.r, 200, "bottom-right should be red: \(bottomRight)")
    }
}
#endif
