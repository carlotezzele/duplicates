import CryptoKit
import Foundation

/// Why a file was not moved to the Trash. Each case is a safety check that failed.
public enum SafetyRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    case outsideScannedFolders(path: String)
    case insidePackage(path: String)
    case pathNowThroughSymlink(path: String)
    case hardLinked(path: String)
    case fileChanged(path: String, detail: String)
    case fileUnreadable(path: String, detail: String)
    case keptFileMissing(path: String)
    case keptFileChanged(path: String, detail: String)
    case sameFileAsKept(path: String)
    case contentDiffers(path: String, kept: String)
    case contentChangedSinceScan(path: String)
    case cancelled

    public var description: String {
        switch self {
        case let .outsideScannedFolders(p): "\(p) is not inside a scanned folder"
        case let .insidePackage(p): "\(p) is inside a package (such as a Photos library)"
        case let .pathNowThroughSymlink(p): "the path to \(p) now goes through a symlink or was renamed"
        case let .hardLinked(p): "\(p) now has hard links; Doppio never trashes hard links"
        case let .fileChanged(p, detail): "\(p) changed since the scan (\(detail))"
        case let .fileUnreadable(p, detail): "\(p) could not be checked (\(detail))"
        case let .keptFileMissing(p): "the file being kept, \(p), is missing"
        case let .keptFileChanged(p, detail): "the file being kept, \(p), changed since the scan (\(detail))"
        case let .sameFileAsKept(p): "\(p) is now the same file as the one being kept"
        case let .contentDiffers(p, kept): "\(p) is no longer identical to \(kept)"
        case let .contentChangedSinceScan(p): "the content of \(p) changed since the scan"
        case .cancelled: "cancelled before this file was checked"
        }
    }
}

/// The checks that must all pass, right before each file is moved to the Trash.
/// They read the disk again instead of trusting the scan.
enum SafetyGuard {
    /// Verifies that `file` may go to the Trash while `kept` stays. Returns the SHA-256
    /// of `file` as read just now (it is logged, and matches the group's hash).
    static func check(_ file: DuplicateFile, keeping kept: DuplicateFile, in group: DuplicateGroup,
                      roots: ScanRoots, cancel: CancelFlag,
                      onBytes: (Int) -> Void = { _ in }) throws(SafetyRefusal) -> String {
        let path = file.path
        if cancel.isCancelled { throw .cancelled }

        // 1. Where it is: inside a scanned folder, by its real path, and not inside a package.
        guard roots.contains(path) else { throw .outsideScannedFolders(path: path) }
        guard let real = ScanRoots.realPath(path) else {
            throw .fileChanged(path: path, detail: "it no longer exists")
        }
        guard real == path else { throw .pathNowThroughSymlink(path: path) }
        guard roots.contains(real) else { throw .outsideScannedFolders(path: path) }
        guard !Exclusions.isInsidePackage(path: (real as NSString).deletingLastPathComponent) else {
            throw .insidePackage(path: path)
        }

        // 2. What it is: the same, unmodified, single-link regular file the scan saw.
        let st: FileStat
        do { st = try FileStat.lstat(path) } catch { throw .fileChanged(path: path, detail: "it no longer exists") }
        do { try file.record.verifySame(as: st) } catch { throw .fileChanged(path: path, detail: Self.detail(error)) }
        guard st.linkCount == 1 else { throw .hardLinked(path: path) }

        // 3. The kept file: still there, unmodified, and a different physical file.
        let keptStat: FileStat
        do { keptStat = try FileStat.lstat(kept.path) } catch { throw .keptFileMissing(path: kept.path) }
        do { try kept.record.verifySame(as: keptStat) } catch {
            throw .keptFileChanged(path: kept.path, detail: Self.detail(error))
        }
        guard keptStat.device != st.device || keptStat.inode != st.inode else { throw .sameFileAsKept(path: path) }

        // 4. Content: byte-identical to the kept file now, and to what was hashed at scan time.
        var hasher = SHA256()
        let identical: Bool
        do {
            identical = try ByteComparer.identical(kept.record, file.record, cancel: cancel, onBytes: onBytes) {
                hasher.update(bufferPointer: $0)
            }
        } catch {
            if case .cancelled = error { throw .cancelled }
            if error.path == kept.path {
                if case .openFailed(_, ENOENT) = error { throw .keptFileMissing(path: kept.path) }
                throw .keptFileChanged(path: kept.path, detail: Self.detail(error))
            }
            switch error {
            case .changed, .notRegularFile: throw .fileChanged(path: path, detail: Self.detail(error))
            default: throw .fileUnreadable(path: path, detail: Self.detail(error))
            }
        }
        guard identical else { throw .contentDiffers(path: path, kept: kept.path) }
        let sha = hasher.finalize().hexString
        guard sha == group.sha256 else { throw .contentChangedSinceScan(path: path) }
        return sha
    }

    private static func detail(_ error: FileAccessError) -> String {
        switch error {
        case let .changed(_, detail): detail
        case .notRegularFile: "no longer a regular file"
        case let .statFailed(_, e), let .openFailed(_, e), let .readFailed(_, e): String(cString: strerror(e))
        case .cancelled: "cancelled"
        }
    }
}
