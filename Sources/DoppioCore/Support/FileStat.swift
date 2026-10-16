import Darwin
import Foundation

/// A POSIX timestamp kept at full (nanosecond) precision so that
/// "has this file changed since the scan?" checks are exact.
public struct Timestamp: Hashable, Sendable, Codable, Comparable {
    public var seconds: Int64
    public var nanoseconds: Int64

    public init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    init(_ ts: timespec) {
        self.init(seconds: Int64(ts.tv_sec), nanoseconds: Int64(ts.tv_nsec))
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    public static func < (a: Timestamp, b: Timestamp) -> Bool {
        (a.seconds, a.nanoseconds) < (b.seconds, b.nanoseconds)
    }
}

/// The subset of `struct stat` Doppio cares about.
struct FileStat: Sendable {
    var device: Int32
    var inode: UInt64
    var mode: UInt16
    var linkCount: UInt16
    var size: Int64
    var blocks: Int64
    var flags: UInt32
    var modified: Timestamp
    var created: Timestamp
    var changed: Timestamp

    init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
        mode = st.st_mode
        linkCount = st.st_nlink
        size = Int64(st.st_size)
        blocks = Int64(st.st_blocks)
        flags = st.st_flags
        modified = Timestamp(st.st_mtimespec)
        created = Timestamp(st.st_birthtimespec)
        changed = Timestamp(st.st_ctimespec)
    }

    /// `lstat`: never follows a symlink.
    static func lstat(_ path: String) throws(FileAccessError) -> FileStat {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { throw .statFailed(path: path, errno: errno) }
        return FileStat(st)
    }

    static func fstat(_ fd: Int32, path: String) throws(FileAccessError) -> FileStat {
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { throw .statFailed(path: path, errno: errno) }
        return FileStat(st)
    }

    var fileType: UInt16 { mode & S_IFMT }
    var isRegular: Bool { fileType == S_IFREG }
    var isDirectory: Bool { fileType == S_IFDIR }
    var isSymlink: Bool { fileType == S_IFLNK }
    var allocatedSize: Int64 { blocks * 512 }
    /// iCloud "Optimize Storage" placeholder: reading it would trigger a download.
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
}

public enum FileAccessError: Error, Sendable, Equatable, CustomStringConvertible {
    case statFailed(path: String, errno: Int32)
    case openFailed(path: String, errno: Int32)
    case readFailed(path: String, errno: Int32)
    case notRegularFile(path: String)
    case changed(path: String, detail: String)
    case cancelled

    public var description: String {
        switch self {
        case let .statFailed(path, e): "cannot read file info for \(path): \(String(cString: strerror(e)))"
        case let .openFailed(path, e): "cannot open \(path): \(String(cString: strerror(e)))"
        case let .readFailed(path, e): "read error in \(path): \(String(cString: strerror(e)))"
        case let .notRegularFile(path): "\(path) is no longer a regular file"
        case let .changed(path, detail): "\(path) changed since it was scanned (\(detail))"
        case .cancelled: "cancelled"
        }
    }

    public var path: String? {
        switch self {
        case let .statFailed(p, _), let .openFailed(p, _), let .readFailed(p, _),
             let .notRegularFile(p), let .changed(p, _): p
        case .cancelled: nil
        }
    }
}
