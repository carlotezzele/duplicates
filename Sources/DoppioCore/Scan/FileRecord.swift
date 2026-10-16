import Foundation

/// One regular file found by the walker, as it was at scan time.
public struct FileRecord: Hashable, Sendable, Codable {
    public let path: String
    public let device: Int32
    public let inode: UInt64
    public let linkCount: UInt16
    public let size: Int64
    public let allocatedSize: Int64
    public let modified: Timestamp
    public let created: Timestamp

    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    var inodeKey: InodeKey { InodeKey(device: device, inode: inode) }

    init(path: String, stat st: FileStat) {
        self.path = path
        device = st.device
        inode = st.inode
        linkCount = st.linkCount
        size = st.size
        allocatedSize = st.allocatedSize
        modified = st.modified
        created = st.created
    }

    /// Throws if `st` (from a fresh `stat`) does not describe the same, unmodified file.
    func verifySame(as st: FileStat) throws(FileAccessError) {
        guard st.isRegular else { throw .notRegularFile(path: path) }
        if st.device != device || st.inode != inode { throw .changed(path: path, detail: "replaced by a different file") }
        if st.size != size { throw .changed(path: path, detail: "size \(size) → \(st.size)") }
        if st.modified != modified { throw .changed(path: path, detail: "modification time changed") }
    }
}

/// Device + inode: the identity of a physical file. Hard links share it.
struct InodeKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}
