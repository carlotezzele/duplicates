import AppKit
import DoppioCore
import QuickLookThumbnailing
import SwiftUI

/// SwiftUI's `State` property wrapper. Recent SDKs also declare a `@State` macro whose
/// plugin ships only with Xcode; with just the Command Line Tools the macro can't expand,
/// so views use this alias, which always resolves to the plain property wrapper.
typealias ViewState = SwiftUI.State

/// Quick Look thumbnails (HEIC, RAW, video, …), cached in memory.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for path: String, side: CGFloat) async -> NSImage? {
        let key = "\(Int(side))|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

struct Thumbnail: View {
    let path: String
    let side: CGFloat

    @ViewState private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.15)
                    .opacity(0.5)
            }
        }
        .frame(width: side, height: side)
        .task(id: path) { image = await ThumbnailCache.shared.image(for: path, side: side) }
    }
}

/// Capture date from the file's metadata, loaded lazily.
struct CaptureDateText: View {
    let path: String
    @ViewState private var date: Date?
    @ViewState private var loaded = false

    var body: some View {
        Text(loaded ? (date.map(Format.date) ?? "—") : "…")
            .task(id: path) {
                date = await CaptureDate.read(path: path)
                loaded = true
            }
    }
}

enum Format {
    static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
    static func bytes(_ n: Int64) -> String { formatBytes(n) }
    /// "1 file", "2 files"; pass `plural` for irregular words ("copy" → "copies").
    static func count(_ n: Int, _ word: String, plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? word : (plural ?? word + "s"))"
    }
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
    /// The containing folder, with the home folder shown as ~.
    static func folder(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }
}

/// A small coloured capsule ("Keep", "To Trash", …).
struct Badge: View {
    let text: String
    let color: Color
    var systemImage: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(color, in: Capsule())
    }
}

struct RevealButton: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        Button {
            model.reveal(path)
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help("Reveal in Finder")
    }
}
