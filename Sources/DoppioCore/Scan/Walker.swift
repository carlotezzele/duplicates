import Foundation

/// Recursively lists the regular files under the scan roots.
/// Uses `lstat` only, so symlinks are never followed; stays on each root's volume.
struct Walker {
    struct Output: Sendable {
        var records: [FileRecord] = []
        var issues: [ScanIssue] = []
        var skipped = SkipStats()
    }

    let roots: ScanRoots
    let includeAllTypes: Bool
    let cancel: CancelFlag

    func walk(onFile: (Int) -> Void) throws(FileAccessError) -> Output {
        var out = Output()
        let media = MediaFilter()

        for root in roots.paths {
            let rootStat = try FileStat.lstat(root)
            var stack = [root]
            while let dir = stack.popLast() {
                try cancel.check()
                let names: [String]
                do {
                    names = try Walker.listDirectory(dir).sorted()
                } catch {
                    out.issues.append(ScanIssue(kind: .unreadableFolder, path: dir,
                                                message: "cannot list folder: \(error)"))
                    continue
                }
                var subfolders: [String] = []
                for name in names {
                    let path = dir == "/" ? "/" + name : dir + "/" + name
                    let st: FileStat
                    do {
                        st = try FileStat.lstat(path)
                    } catch {
                        out.issues.append(ScanIssue(error, fallbackPath: path))
                        continue
                    }

                    if st.isSymlink {
                        out.skipped.symlinks += 1
                    } else if st.isDirectory {
                        if Exclusions.isExcludedFolder(name: name) {
                            out.skipped.systemFolders += 1
                        } else if st.device != rootStat.device {
                            out.skipped.otherVolumeFolders += 1
                        } else if Exclusions.isPackage(path: path) {
                            out.skipped.packages += 1
                        } else {
                            subfolders.append(path)
                        }
                    } else if st.isRegular {
                        if Exclusions.isExcludedFile(name: name) {
                            out.skipped.metadataFiles += 1
                        } else if st.size == 0 {
                            out.skipped.zeroByte += 1
                        } else if !includeAllTypes && !media.isMedia(name: name) {
                            out.skipped.notMedia += 1
                        } else if st.isDataless {
                            out.issues.append(ScanIssue(kind: .notDownloaded, path: path,
                                                        message: "iCloud placeholder, not downloaded to this Mac; skipped"))
                        } else {
                            out.records.append(FileRecord(path: path, stat: st))
                            onFile(out.records.count)
                        }
                    } else {
                        out.skipped.specialFiles += 1
                    }
                }
                // Reverse so the stack pops folders in sorted order.
                stack.append(contentsOf: subfolders.reversed())
            }
        }
        return out
    }

    /// Every entry in a folder except "." and "..". Uses readdir directly because
    /// FileManager.contentsOfDirectory silently hides AppleDouble "._" files, and
    /// Doppio must see (and deliberately skip) everything itself.
    static func listDirectory(_ path: String) throws(FileAccessError) -> [String] {
        guard let dir = opendir(path) else { throw .openFailed(path: path, errno: errno) }
        defer { closedir(dir) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw .readFailed(path: path, errno: errno) }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
