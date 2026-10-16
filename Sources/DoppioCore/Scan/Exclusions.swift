import Foundation
import UniformTypeIdentifiers

/// What the walker never looks at.
public enum Exclusions {
    /// Exact file names that are never photos.
    public static let fileNames: Set<String> = [".DS_Store", ".localized", "Icon\r"]

    /// Folders that belong to the system, never to the user's photos.
    public static let folderNames: Set<String> = [
        ".Trashes", ".Trash", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", ".MobileBackups", ".PKInstallSandboxManager",
    ]

    /// Package/bundle extensions skipped even if Launch Services doesn't know them
    /// (e.g. a Photos library copied to a Mac without Photos registered). Lowercase.
    public static let bundleExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "migratedaplibrary",
        "imovielibrary", "tvlibrary", "theater", "fcpbundle", "lrlibrary",
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc",
        "xcodeproj", "xcworkspace", "playground", "rtfd", "pages", "numbers", "key",
    ]

    /// AppleDouble metadata ("._name") and known system files.
    public static func isExcludedFile(name: String) -> Bool {
        name.hasPrefix("._") || fileNames.contains(name)
    }

    public static func isExcludedFolder(name: String) -> Bool {
        folderNames.contains(name)
    }

    /// True if the directory at `path` is a package (its contents are never scanned).
    public static func isPackage(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty, bundleExtensions.contains(ext) { return true }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// True if `path` is a package or lies inside one. Used to reject scan roots.
    public static func isInsidePackage(path: String) -> Bool {
        var current = path
        while current != "/" && !current.isEmpty {
            if isPackage(path: current) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }
}

/// Decides whether a file is a photo or video, by extension → UTType conformance.
final class MediaFilter {
    private var cache: [String: Bool] = [:]

    func isMedia(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let known = cache[ext] { return known }
        let result: Bool
        if let type = UTType(filenameExtension: ext) {
            result = type.conforms(to: .image) || type.conforms(to: .movie)
        } else {
            result = false
        }
        cache[ext] = result
        return result
    }
}
