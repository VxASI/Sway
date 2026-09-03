#if os(macOS)
import CoreGraphics
import Dispatch
import Foundation
import SwayCore

public enum CursorTrackingError: Error, CustomStringConvertible {
    case eventTapCreationFailed

    public var description: String {
        switch self {
        case .eventTapCreationFailed:
            return """
            Could not create a CGEventTap. Grant the recording process Input \
            Monitoring (and Accessibility, if prompted) in System Settings > \
            Privacy & Security, then try again.
            """
        }
    }
}

/// Global pointer tracking: a listen-only `CGEventTap` for the real movement
/// path, plus a low-rate positional sampler as a safety net.
///
/// The tap callback does the minimum possible work - timestamp, convert,
/// enqueue, return - because anything slower risks the tap being disabled by
/// timeout and delays event delivery system-wide.
public final class GlobalCursorTracker: @unchecked Sendable {
    private let geometry: CaptureGeometry
    private let bridge: HostClockBridge
    private let sampleHz: Double

    private let tapEvents = CursorEventBuffer()
    private let sampleEvents = CursorEventBuffer()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var sampleTimer: DispatchSourceTimer?
    private let sampleQueue = DispatchQueue(label: "ai.sway.cursor-sampler", qos: .userInitiated)

    public init(geometry: CaptureGeometry, bridge: HostClockBridge, sampleHz: Double = 20) {
        self.geometry = geometry
        self.bridge = bridge
        self.sampleHz = sampleHz
    }

    private static let mouseTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .leftMouseDragged, .rightMouseDragged,
        .scrollWheel
    ]

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
    }

    /// Whether key presses are being recorded (timestamps only). False when
    /// the system only allowed a mouse-only tap.
    public private(set) var recordsKeyPresses = false

    public func start() throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<GlobalCursorTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        // Key presses let the editor hide the cursor while typing. Only the
        // moment is kept, never the key. If the system refuses a tap that
        // includes keyboard events, fall back to mouse-only rather than
        // failing the recording.
        var tapOrNil = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: GlobalCursorTracker.mask(GlobalCursorTracker.mouseTypes + [.keyDown]),
            callback: callback,
            userInfo: refcon
        )
        recordsKeyPresses = tapOrNil != nil
        if tapOrNil == nil {
            tapOrNil = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: GlobalCursorTracker.mask(GlobalCursorTracker.mouseTypes),
                callback: callback,
                userInfo: refcon
            )
        }
        guard let tap = tapOrNil else {
            throw CursorTrackingError.eventTapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        // The tap gets its own thread and run loop so a busy main thread can
        // never stall event delivery.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "ai.sway.cursor-event-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        startSampling()
    }

    public func stop() {
        sampleTimer?.cancel()
        sampleTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop, let runLoopSource {
            CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
            CFRunLoopStop(runLoop)
        }
        runLoop = nil
        runLoopSource = nil
        eventTap = nil
        thread = nil
    }

    /// The merged track: tap events, with sampler positions filled in wherever
    /// the tap stream went quiet or coalesced movement.
    public func track() -> CursorTrack {
        CursorTrack.merge(tapEvents: tapEvents.snapshot(), samples: sampleEvents.snapshot())
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // A tap that is disabled (usually because a callback took too long, or
        // after a permission change) stops delivering until re-enabled.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard let kind = GlobalCursorTracker.eventType(for: type) else { return }

        let time = bridge.timebase.elapsed()
        let location = event.location
        let point = geometry.normalize(globalX: Double(location.x), globalY: Double(location.y))

        var scrollDeltaX: Double?
        var scrollDeltaY: Double?
        if kind == .scrollWheel {
            scrollDeltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            scrollDeltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        }

        tapEvents.append(
            CursorEvent(
                time: time,
                x: point.x,
                y: point.y,
                type: kind,
                scrollDeltaX: scrollDeltaX,
                scrollDeltaY: scrollDeltaY
            )
        )
    }

    private static func eventType(for type: CGEventType) -> CursorEventType? {
        switch type {
        case .mouseMoved: return .move
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseUp: return .leftMouseUp
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseUp: return .rightMouseUp
        case .leftMouseDragged: return .leftMouseDragged
        case .rightMouseDragged: return .rightMouseDragged
        case .scrollWheel: return .scrollWheel
        case .keyDown: return .keyDown
        default: return nil
        }
    }

    private func startSampling() {
        guard sampleHz > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        let interval = 1 / sampleHz
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let location = CGEvent(source: nil)?.location else { return }
            let time = self.bridge.timebase.elapsed()
            let point = self.geometry.normalize(globalX: Double(location.x), globalY: Double(location.y))
            self.sampleEvents.append(CursorEvent(time: time, x: point.x, y: point.y, type: .sample))
        }
        timer.resume()
        sampleTimer = timer
    }
}
#endif
