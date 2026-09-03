import AVFoundation
import AppKit
import CoreImage
import MetalKit
import SwayCapture
import SwayCore
import SwiftUI

/// The editor preview. `AVPlayer` only plays the raw movie (and its audio);
/// this view redraws at 60 Hz on the GPU, pulling whichever source frame is
/// current and rendering the camera and cursor at *their* current positions.
///
/// That decoupling is what makes playback smooth: ScreenCaptureKit records a
/// frame only when the screen changes (often ~10 fps), and an
/// `AVVideoComposition` re-renders only on those frames. Here the camera moves
/// every tick regardless. Rendering at the view's size instead of the capture
/// size also keeps each frame cheap.
struct PreviewView: NSViewRepresentable {
    @ObservedObject var editor: EditorModel

    func makeNSView(context: Context) -> PreviewMetalView {
        let view = PreviewMetalView(frame: .zero, source: editor.preview)
        view.isPlaying = editor.isPlaying
        return view
    }

    func updateNSView(_ view: PreviewMetalView, context: Context) {
        view.isPlaying = editor.isPlaying
        // Any published change (a landed seek via `frameRevision`, a segment
        // drag, a style edit) is a reason to redraw the paused frame.
        _ = editor.frameRevision
        if !editor.isPlaying { view.setNeedsDisplay(view.bounds) }
    }
}

/// Everything the preview needs to draw a frame, shared with the model.
final class PreviewSource {
    let player: AVPlayer
    let output: AVPlayerItemVideoOutput
    let camera: CameraBox
    let cursor: CursorBox
    let canvas: CanvasBox
    let captureSize: CGSize

    init(
        player: AVPlayer,
        item: AVPlayerItem,
        camera: CameraBox,
        cursor: CursorBox,
        canvas: CanvasBox,
        captureSize: CGSize
    ) {
        self.player = player
        self.camera = camera
        self.cursor = cursor
        self.canvas = canvas
        self.captureSize = captureSize
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
    }
}

final class PreviewMetalView: MTKView, MTKViewDelegate {
    private let source: PreviewSource
    private let renderer: MetalFrameRenderer?
    private var lastPixelBuffer: CVPixelBuffer?
    private var firstFrameRetries = 0

    /// While playing the view runs its own 60 Hz loop; paused, it only redraws
    /// on demand so an idle editor costs nothing.
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            isPaused = !isPlaying
            enableSetNeedsDisplay = !isPlaying
            if isPlaying {
                // An output that was not polled for a while suspends itself;
                // this wakes it before the first frame is needed.
                source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.05)
            } else {
                setNeedsDisplay(bounds)
            }
        }
    }

    init(frame: CGRect, source: PreviewSource) {
        self.source = source
        self.renderer = MetalFrameRenderer()
        super.init(frame: frame, device: renderer?.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        preferredFramesPerSecond = 60
        isPaused = true
        enableSetNeedsDisplay = true
        layer?.backgroundColor = NSColor.black.cgColor
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setNeedsDisplay(bounds)
    }

    func draw(in view: MTKView) {
        guard let renderer,
              let drawable = currentDrawable,
              drawableSize.width > 0, drawableSize.height > 0 else { return }

        // The frame the player is showing right now. When paused after a
        // seek the output has exactly one new frame; between source frames it
        // has none and we keep drawing the last one.
        let itemTime = source.output.itemTime(forHostTime: CACurrentMediaTime())
        if source.output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = source.output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastPixelBuffer = buffer
        } else if lastPixelBuffer == nil, firstFrameRetries < 100 {
            // Nothing decoded yet (first open, or a suspended output): ask for
            // frames and try again shortly, for up to ~5 s.
            firstFrameRetries += 1
            source.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.05)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.setNeedsDisplay(self.bounds)
            }
            return
        }
        guard let pixelBuffer = lastPixelBuffer else { return }

        let time = source.player.currentTime().seconds
        let state = source.camera.path.state(at: time)
            ?? CameraKeyframe(time: time, centerX: 0.5, centerY: 0.5, zoom: 1)
        let image = CameraFrameRenderer.render(
            source: CIImage(cvPixelBuffer: pixelBuffer),
            camera: state,
            time: time,
            outputSize: drawableSize,
            cursor: source.cursor.renderer,
            canvas: source.canvas.style
        )

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
        renderer.render(image, to: drawable.texture, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
