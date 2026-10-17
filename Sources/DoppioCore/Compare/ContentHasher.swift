import CryptoKit
import Foundation

enum ContentHasher {
    /// Bytes hashed from each end of a file in the quick check.
    static let edgeSize = 64 * 1024
    /// Files this small skip the quick check: it would read the whole file anyway.
    static var quickCheckThreshold: Int64 { Int64(edgeSize * 2) }

    /// SHA-256 of the first and last 64 KB. Only used to rule files out.
    static func quickHash(_ record: FileRecord, cancel: CancelFlag) throws(FileAccessError) -> String {
        try cancel.check()
        let file = try OpenFile(record)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: edgeSize, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        for offset in [0, record.size - Int64(edgeSize)] {
            let n = try file.read(into: buffer, count: edgeSize, at: offset)
            guard n == edgeSize else { throw .changed(path: record.path, detail: "file got shorter while reading") }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        try file.verifyUnchanged()
        return hasher.finalize().hexString
    }

    /// SHA-256 of the whole file. `onBytes` is called after each chunk for progress.
    static func fullHash(_ record: FileRecord, cancel: CancelFlag,
                         onBytes: (Int) -> Void) throws(FileAccessError) -> String {
        let file = try OpenFile(record)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: readChunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var offset: Int64 = 0
        while true {
            try cancel.check()
            let n = try file.read(into: buffer, count: readChunkSize, at: offset)
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            offset += Int64(n)
            onBytes(n)
        }
        guard offset == record.size else {
            throw .changed(path: record.path, detail: "read \(offset) bytes, expected \(record.size)")
        }
        try file.verifyUnchanged()
        return hasher.finalize().hexString
    }
}

enum ByteComparer {
    /// Compares two files byte by byte. Both must still match their scan records.
    /// `onChunkOfB` sees every chunk of `b` as it is read (used to hash it in the same pass).
    static func identical(_ a: FileRecord, _ b: FileRecord, cancel: CancelFlag,
                          onBytes: (Int) -> Void,
                          onChunkOfB: (UnsafeRawBufferPointer) -> Void = { _ in }) throws(FileAccessError) -> Bool {
        guard a.size == b.size else { return false }
        let fa = try OpenFile(a)
        let fb = try OpenFile(b)
        let ba = UnsafeMutableRawBufferPointer.allocate(byteCount: readChunkSize, alignment: 16)
        let bb = UnsafeMutableRawBufferPointer.allocate(byteCount: readChunkSize, alignment: 16)
        defer { ba.deallocate(); bb.deallocate() }
        var offset: Int64 = 0
        while true {
            try cancel.check()
            let na = try fa.read(into: ba, count: readChunkSize, at: offset)
            let nb = try fb.read(into: bb, count: readChunkSize, at: offset)
            guard na == nb else { return false }
            if na == 0 { break }
            guard memcmp(ba.baseAddress!, bb.baseAddress!, na) == 0 else { return false }
            onChunkOfB(UnsafeRawBufferPointer(rebasing: bb[0..<nb]))
            offset += Int64(na)
            onBytes(2 * na)
        }
        guard offset == a.size else {
            throw .changed(path: a.path, detail: "read \(offset) bytes, expected \(a.size)")
        }
        try fa.verifyUnchanged()
        try fb.verifyUnchanged()
        return true
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
