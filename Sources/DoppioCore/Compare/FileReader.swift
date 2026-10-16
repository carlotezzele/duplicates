import Darwin
import Foundation

/// A file opened strictly read-only (`O_RDONLY | O_NOFOLLOW`), bypassing the page
/// cache (`F_NOCACHE`) so large scans don't evict everything else from memory.
/// Opening verifies the file is still exactly the one recorded at scan time.
final class OpenFile {
    let fd: Int32
    let record: FileRecord

    init(_ record: FileRecord) throws(FileAccessError) {
        let fd = Darwin.open(record.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .openFailed(path: record.path, errno: errno) }
        self.fd = fd
        self.record = record
        _ = fcntl(fd, F_NOCACHE, 1)
        try verifyUnchanged()
    }

    deinit { Darwin.close(fd) }

    func verifyUnchanged() throws(FileAccessError) {
        try record.verifySame(as: FileStat.fstat(fd, path: record.path))
    }

    /// Reads up to `count` bytes at `offset`, looping over short reads. Returns bytes read (0 at EOF).
    func read(into buffer: UnsafeMutableRawBufferPointer, count: Int, at offset: Int64) throws(FileAccessError) -> Int {
        var total = 0
        while total < count {
            let n = pread(fd, buffer.baseAddress! + total, count - total, off_t(offset) + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                throw .readFailed(path: record.path, errno: errno)
            }
            if n == 0 { break }
            total += n
        }
        return total
    }
}

/// Process-wide I/O settings applied before scanning.
public enum IOPolicy {
    /// Make reads of iCloud placeholder ("dataless") files fail instead of downloading them,
    /// so scanning never changes what is stored on disk. The walker already skips files it
    /// sees as dataless; this closes the gap for files evicted mid-scan.
    public static func disableDatalessMaterialization() {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }
}

let readChunkSize = 1 << 20 // 1 MiB
