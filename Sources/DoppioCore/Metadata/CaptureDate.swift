import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// When a photo or video was taken, from its own metadata (EXIF for images, QuickTime
/// creation date for videos). Read-only; used to help choose which copy to keep.
public enum CaptureDate {
    public static func read(path: String) async -> Date? {
        let url = URL(fileURLWithPath: path)
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
            return await videoDate(url)
        }
        return imageDate(url)
    }

    static func imageDate(_ url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parseExif(text, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    /// "2024:05:01 10:21:33" plus an optional "+02:00". Without an offset, EXIF time is local time.
    static func parseExif(_ text: String, offset: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = f.date(from: text.trimmingCharacters(in: .whitespaces) + offset) { return date }
        }
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func videoDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }
}
