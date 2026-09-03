#if os(macOS)
import AppKit
import Foundation
import SwayCore

/// Records which pointer the user actually saw - arrow, I-beam, hand, resize
/// arrows - so the editor can draw the real one back in.
///
/// The event tap only reports positions; the pointer image is read from
/// `NSCursor.currentSystem` on a timer. Each distinct image is stored once (by
/// content hash) as a PNG, and the timeline only records when the shape
/// switched. A recording where this yields nothing (some hosts return no
/// system cursor) simply falls back to Sway's arrow at render time.
public final class CursorShapeRecorder: @unchecked Sendable {
    private let bridge: HostClockBridge
    private let sampleHz: Double
    private let lock = NSLock()
    private var shapes: [String: (shape: CursorShape, png: Data)] = [:]
    private var changes: [CursorShapeChange] = []
    private var lastShapeID: String?
    private var timer: DispatchSourceTimer?

    public init(bridge: HostClockBridge, sampleHz: Double = 15) {
        self.bridge = bridge
        self.sampleHz = sampleHz
    }

    public func start() {
        guard sampleHz > 0 else { return }
        // AppKit's cursor state belongs to the main thread.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = 1 / sampleHz
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// The recorded timeline. `writePNGs(to:)` stores the images themselves.
    public func track() -> CursorShapeTrack {
        lock.lock()
        defer { lock.unlock() }
        return CursorShapeTrack(
            shapes: shapes.values.map(\.shape).sorted { $0.id < $1.id },
            changes: changes
        )
    }

    public func writePNGs(to directory: URL) throws {
        lock.lock()
        let entries = shapes.values.map { ($0.shape.fileName, $0.png) }
        lock.unlock()
        guard !entries.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (fileName, png) in entries {
            try png.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        }
    }

    // MARK: - Sampling

    private func sample() {
        guard let cursor = NSCursor.currentSystem else { return }
        let time = bridge.timebase.elapsed()
        let image = cursor.image
        let hotspot = cursor.hotSpot

        // Hash the bitmap, not the NSImage object - the system hands out new
        // objects for the same pointer. The raw pixels (a few KB) are far
        // cheaper to hash than a TIFF encoding.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bytes = cgImage.dataProvider?.data else { return }
        let id = CursorShapeRecorder.fingerprint(bytes as Data)

        lock.lock()
        defer { lock.unlock() }
        if id == lastShapeID { return }
        lastShapeID = id
        if shapes[id] == nil {
            guard let png = CursorShapeRecorder.png(from: cgImage) else { return }
            shapes[id] = (
                CursorShape(
                    id: id,
                    fileName: "\(id).png",
                    width: Double(image.size.width),
                    height: Double(image.size.height),
                    hotspotX: Double(hotspot.x),
                    hotspotY: Double(hotspot.y)
                ),
                png
            )
        }
        changes.append(CursorShapeChange(time: time, shapeID: id))
    }

    /// FNV-1a over the bytes: stable within and across runs, cheap enough for
    /// a 32x32 cursor fifteen times a second.
    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func png(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
#endif
