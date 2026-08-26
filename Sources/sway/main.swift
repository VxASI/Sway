import Foundation
import SwayCore

#if os(macOS)
import AVFoundation
import SwayCapture
#endif

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    sway - cinematic screen recording

    USAGE:
      sway record [options]      record until Return is pressed
      sway export <bundle> <out.mp4> [--no-cursor] [--width <px>]
                                 render with camera moves and drawn cursor
      sway inspect <bundle>      summarize a .sway bundle
      sway recamera <bundle>     regenerate camera.json from cursor.json

    RECORD OPTIONS:
      --output <path>            bundle path (default: ~/Movies/Sway/<date>.sway)
      --display <id>             CGDirectDisplayID to capture (default: main)
      --window <id>              CGWindowID to capture instead of a display
      --fps <n>                  capture frame rate (default: 60)
      --no-audio                 skip system audio
      --duration <seconds>       stop automatically after N seconds
    """)
}

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func summarize(bundleAt path: String) throws {
    let bundle = SwayProjectBundle(url: URL(fileURLWithPath: path))
    let project = try bundle.readProject()
    let track = try bundle.readCursorTrack()
    let clicks = track.events.filter { $0.type.isClickDown }.count
    print("duration        \(String(format: "%.2f", project.duration))s")
    print("capture         \(project.geometry.pixelWidth)x\(project.geometry.pixelHeight)px "
        + "@\(String(format: "%.1f", project.geometry.scale))x, display \(project.geometry.displayID)")
    print("cursor events   \(track.events.count) (\(clicks) clicks)")
    if let camera = try? bundle.readCameraPath() {
        let zoomed = camera.keyframes.filter { $0.zoom > 1.01 }.count
        print("camera          \(camera.keyframes.count) keyframes, "
            + "\(String(format: "%.0f", Double(zoomed) / Double(max(1, camera.keyframes.count)) * 100))% zoomed in")
    }
}

func regenerateCamera(bundleAt path: String) throws {
    let bundle = SwayProjectBundle(url: URL(fileURLWithPath: path))
    let project = try bundle.readProject()
    let track = try bundle.readCursorTrack()
    let camera = CameraPathGenerator().generate(track: track, duration: project.duration)
    try bundle.write(project: project, track: track, camera: camera)
    print("wrote \(camera.keyframes.count) camera keyframes to \(bundle.cameraURL.path)")
}

func defaultBundleURL() -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let name = "\(formatter.string(from: Date())).\(SwayProjectBundle.pathExtension)"
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Sway", isDirectory: true)
        .appendingPathComponent(name)
}

guard let command = arguments.first else {
    printUsage()
    exit(1)
}

switch command {
case "inspect":
    guard arguments.count > 1 else {
        printUsage()
        exit(1)
    }
    do {
        try summarize(bundleAt: arguments[1])
    } catch {
        FileHandle.standardError.write(Data("sway: \(error)\n".utf8))
        exit(1)
    }

case "export":
    #if os(macOS)
    guard arguments.count > 2 else {
        printUsage()
        exit(1)
    }
    let exportBundle = SwayProjectBundle(url: URL(fileURLWithPath: arguments[1]))
    let destination = URL(fileURLWithPath: arguments[2])
    var exportOptions = ExportOptions()
    if arguments.contains("--no-cursor") { exportOptions.drawsCursor = false }
    if let width = value(for: "--width").flatMap(Double.init) {
        let aspect = (try? exportBundle.readProject())?.geometry.aspectRatio ?? (16.0 / 9)
        exportOptions.size = CGSize(width: width, height: (width / aspect).rounded())
    }
    let exporter = CinematicExporter(bundle: exportBundle, options: exportOptions)
    Task {
        do {
            try await exporter.export(to: destination)
            print("exported to \(destination.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("sway: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
    #else
    FileHandle.standardError.write(Data("sway: export requires macOS 13 or later\n".utf8))
    exit(1)
    #endif

case "recamera":
    guard arguments.count > 1 else {
        printUsage()
        exit(1)
    }
    do {
        try regenerateCamera(bundleAt: arguments[1])
    } catch {
        FileHandle.standardError.write(Data("sway: \(error)\n".utf8))
        exit(1)
    }

case "record":
    #if os(macOS)
    let bundleURL = value(for: "--output").map { URL(fileURLWithPath: $0) } ?? defaultBundleURL()
    var options = ScreenRecorderOptions()
    if let fps = value(for: "--fps").flatMap(Int.init) { options.frameRate = fps }
    if let display = value(for: "--display").flatMap(UInt32.init) { options.target = .display(display) }
    if let window = value(for: "--window").flatMap(UInt32.init) { options.target = .window(window) }
    if arguments.contains("--no-audio") { options.capturesSystemAudio = false }
    let autoStop = value(for: "--duration").flatMap(Double.init)

    let session = RecordingSession(bundleURL: bundleURL, options: options)

    Task {
        do {
            try await session.start()
            print("recording to \(bundleURL.path)")
            if let autoStop {
                print("stopping in \(autoStop)s")
                try await Task.sleep(nanoseconds: UInt64(autoStop * 1_000_000_000))
            } else {
                print("press Return to stop")
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        _ = readLine()
                        continuation.resume()
                    }
                }
            }
            let result = try await session.stop()
            print("saved \(String(format: "%.2f", result.project.duration))s to \(bundleURL.path)")
            try summarize(bundleAt: bundleURL.path)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("sway: \(error)\n".utf8))
            exit(1)
        }
    }

    dispatchMain()
    #else
    FileHandle.standardError.write(Data("sway: recording requires macOS 13 or later\n".utf8))
    exit(1)
    #endif

default:
    printUsage()
    exit(1)
}
