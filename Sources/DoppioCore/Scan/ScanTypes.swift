import Foundation

public struct ScanOptions: Sendable {
    public var roots: [URL]
    /// false = only images and videos (UTType .image / .movie).
    public var includeAllTypes: Bool
    /// Concurrent file reads. Keep low (1) for spinning external disks.
    public var jobs: Int

    public init(roots: [URL], includeAllTypes: Bool = false, jobs: Int = 1) {
        self.roots = roots
        self.includeAllTypes = includeAllTypes
        self.jobs = max(1, jobs)
    }
}

public enum ScanPhase: String, Sendable {
    case walking = "Listing files"
    case quickHash = "Quick check"
    case fullHash = "Hashing"
    case verifying = "Comparing byte by byte"
    case finishing = "Finishing"
}

public struct ScanProgress: Sendable {
    public var phase: ScanPhase
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0

    public var fraction: Double? {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        if filesTotal > 0 { return min(1, Double(filesDone) / Double(filesTotal)) }
        return nil
    }
}

/// A file or folder Doppio could not process. It is never treated as unique or duplicate.
public struct ScanIssue: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case unreadableFile = "unreadable_file"
        case unreadableFolder = "unreadable_folder"
        case changedDuringScan = "changed_during_scan"
        case notDownloaded = "not_downloaded"
        case contentMismatch = "content_mismatch"
    }

    public var kind: Kind
    public var path: String
    public var message: String

    public init(kind: Kind, path: String, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }

    init(_ error: FileAccessError, fallbackPath: String) {
        let kind: Kind = switch error {
        case .changed, .notRegularFile: .changedDuringScan
        default: .unreadableFile
        }
        self.init(kind: kind, path: error.path ?? fallbackPath, message: error.description)
    }
}

/// Things deliberately not considered, by reason.
public struct SkipStats: Hashable, Sendable, Codable {
    public var symlinks = 0
    public var zeroByte = 0
    public var notMedia = 0
    public var metadataFiles = 0
    public var systemFolders = 0
    public var packages = 0
    public var otherVolumeFolders = 0
    public var specialFiles = 0

    public init() {}

    public var lines: [(String, Int)] {
        [
            ("symlinks (not followed)", symlinks),
            ("zero-byte files", zeroByte),
            ("non-photo/video files", notMedia),
            ("metadata files (._*, .DS_Store)", metadataFiles),
            ("system folders (.Trashes, .Spotlight-V100, …)", systemFolders),
            ("packages/bundles (e.g. Photos libraries)", packages),
            ("folders on another volume (mount points)", otherVolumeFolders),
            ("special files (pipes, sockets, devices)", specialFiles),
        ].filter { $0.1 > 0 }
    }
}

public enum ScanError: Error, Sendable, CustomStringConvertible, Equatable {
    case noRoots
    case invalidRoot(path: String, reason: String)

    public var description: String {
        switch self {
        case .noRoots: "No folders to scan."
        case let .invalidRoot(path, reason): "Cannot scan \(path): \(reason)"
        }
    }
}
