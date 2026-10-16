import Darwin
import Foundation

/// The validated, symlink-resolved set of folders a scan covers.
/// Only files inside these folders can ever be acted on.
public struct ScanRoots: Sendable, Hashable {
    public let paths: [String]

    public init(_ urls: [URL]) throws(ScanError) {
        guard !urls.isEmpty else { throw .noRoots }
        var resolved: [String] = []
        for url in urls {
            let given = url.path
            guard let real = ScanRoots.realPath(given) else {
                throw .invalidRoot(path: given, reason: "it does not exist or cannot be accessed")
            }
            guard let st = try? FileStat.lstat(real), st.isDirectory else {
                throw .invalidRoot(path: given, reason: "it is not a folder")
            }
            if Exclusions.isInsidePackage(path: real) {
                throw .invalidRoot(path: given, reason: "it is (or is inside) a package such as a Photos library; Doppio never touches package contents")
            }
            resolved.append(real)
        }
        // Drop roots nested inside other roots so no file is visited twice.
        var kept: [String] = []
        for path in Set(resolved).sorted() where !kept.contains(where: { ScanRoots.isPath(path, inside: $0) }) {
            kept.append(path)
        }
        paths = kept
    }

    /// True if `path` (already resolved) is inside one of the roots.
    public func contains(_ path: String) -> Bool {
        paths.contains { ScanRoots.isPath(path, inside: $0) && path != $0 }
    }

    /// Component-wise containment: "/a/bc" is not inside "/a/b".
    public static func isPath(_ path: String, inside root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// `realpath(3)`: resolves symlinks and `..` in every component.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
