import AVFoundation
import AppKit
import SwayCore
import SwiftUI

/// One past recording in `~/Movies/Sway`, with just enough metadata for the
/// welcome screen's library grid.
struct LibraryItem: Identifiable {
    let url: URL
    let name: String
    let createdAt: Date
    let duration: TimeInterval
    let thumbnail: CGImage?

    var id: URL { url }

    var subtitle: String {
        let total = Int(duration.rounded())
        let length = String(format: "%d:%02d", total / 60, total % 60)
        return "\(LibraryItem.dateFormatter.string(from: createdAt)) · \(length)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Reads every `.sway` bundle in `directory`, newest first. Thumbnails are
    /// the recording's first frame; a bundle whose metadata cannot be read is
    /// skipped rather than crashing the whole library.
    static func scan(directory: URL) async -> [LibraryItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var items: [LibraryItem] = []
        for url in urls where url.pathExtension == SwayProjectBundle.pathExtension {
            let bundle = SwayProjectBundle(url: url)
            guard let project = try? bundle.readProject() else { continue }
            let thumbnail = await firstFrame(of: bundle.videoURL)
            items.append(LibraryItem(
                url: url,
                name: project.name ?? url.deletingPathExtension().lastPathComponent,
                createdAt: project.createdAt,
                duration: project.duration,
                thumbnail: thumbnail
            ))
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    private static func firstFrame(of videoURL: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: CMTime(seconds: 0.1, preferredTimescale: 600))]
            ) { _, image, _, _, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// The library grid on the welcome screen: every past recording, newest first,
/// one click from reopening in the editor.
struct LibraryGrid: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        if model.isLoadingLibrary {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else if model.library.isEmpty {
            Text("Recordings you make will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(model.library) { item in
                    LibraryTile(item: item)
                        .onTapGesture { model.open(url: item.url) }
                }
            }
        }
    }
}

private struct LibraryTile: View {
    let item: LibraryItem
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.06))
                if let thumbnail = item.thumbnail {
                    Image(thumbnail, scale: 1, label: Text(item.name))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
            .clipped()
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isHovering ? Color.accentColor : Color.white.opacity(0.1),
                        lineWidth: isHovering ? 2 : 1
                    )
            }

            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
