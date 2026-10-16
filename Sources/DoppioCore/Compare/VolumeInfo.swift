import Darwin
import Foundation

/// How much space trashing a file would really free.
enum SpaceInfo {
    /// Bytes owned only by this file (not shared with APFS clones), via
    /// `getattrlist(ATTR_CMNEXT_PRIVATESIZE)`. nil if the volume doesn't report it.
    static func privateSize(path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(bitPattern: Int32(bitPattern: UInt32(ATTR_CMN_RETURNED_ATTRS)))
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)

        let size = 64
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        guard getattrlist(path, &request, buffer, size, options) == 0 else { return nil }

        // Layout: u_int32 length, attribute_set_t (5 × u_int32), then the values.
        let returnedForkAttrs = buffer.loadUnaligned(fromByteOffset: 4 + 4 * 4, as: UInt32.self)
        guard returnedForkAttrs & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
        return buffer.loadUnaligned(fromByteOffset: 4 + 5 * 4, as: Int64.self)
    }

    /// File system type name ("apfs", "hfs", "exfat", "smbfs", …).
    static func fileSystemType(path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
