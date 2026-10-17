import Darwin
import Foundation
import Testing
@testable import DoppioCore

/// Stands in for the system Trash: moves files into a folder outside the scanned tree,
/// never overwriting. (`RealTrashTests` uses the real Trash.)
struct FolderTrash: TrashMover {
    let folder: URL

    func moveToTrash(_ path: String) throws -> String? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent).path
        guard renamex_np(path, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        return destination
    }
}

/// A volume without a Trash: every move fails.
struct NoTrash: TrashMover {
    func moveToTrash(_ path: String) throws -> String? { throw CocoaError(.featureUnsupported) }
}

/// Calls `onMove` after each successful move (used to cancel mid-session).
struct ObservedTrash: TrashMover {
    let inner: FolderTrash
    let onMove: @Sendable () -> Void

    func moveToTrash(_ path: String) throws -> String? {
        defer { onMove() }
        return try inner.moveToTrash(path)
    }
}

extension Fixture {
    var trashFolder: URL { base.appendingPathComponent("FakeTrash", isDirectory: true) }
    var logFolder: URL { outside.appendingPathComponent("logs", isDirectory: true) }

    func scan() async throws -> ScanResult {
        try await DuplicateFinder(options: ScanOptions(roots: [root])).run()
    }

    func cleaner(_ result: ScanResult, mover: (any TrashMover)? = nil) -> Cleaner {
        Cleaner(roots: result.roots, logDirectory: logFolder, mover: mover ?? FolderTrash(folder: trashFolder))
    }

    func group(_ result: ScanResult, containing relative: String) throws -> DuplicateGroup {
        try #require(result.groups.first { $0.files.contains { self.relative($0.path) == relative } })
    }

    func plan(_ result: ScanResult, keep: String, trash: String) throws -> TrashPlan {
        let group = try group(result, containing: keep)
        return try TrashPlan(group: group, keep: realPath(keep), trash: [realPath(trash)])
    }

    func contents(_ relative: String) -> Data? { FileManager.default.contents(atPath: path(relative)) }

    func exists(_ relative: String) -> Bool { (try? FileStat.lstat(realPath(relative))) != nil }

    /// Moves a file or folder out of the tree (simulates the user moving it after the scan).
    func moveAway(_ relative: String) throws {
        let destination = outside.appendingPathComponent("moved-" + UUID().uuidString).path
        guard renamex_np(realPath(relative), destination, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
    }

    /// Rewrites a file with the same size, then puts its modification time back.
    func overwriteKeepingMtime(_ relative: String, with data: Data) throws {
        let st = try FileStat.lstat(realPath(relative))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: realPath(relative)))
        try handle.write(contentsOf: data)
        try handle.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(st.modified.seconds), tv_nsec: Int(st.modified.nanoseconds))]
        guard utimensat(AT_FDCWD, realPath(relative), &times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
    }
}

struct CleanTests {
    // MARK: - Plans

    @Test func planInvariants() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.scan()
        let photo = try fixture.group(result, containing: "mac/photo.jpg")
        let keep = fixture.realPath("mac/photo.jpg")
        let copy = fixture.realPath("mac/photo copy.jpg")

        #expect(throws: PlanError.keptFileNotInGroup(fixture.realPath("win/pic.jpg"))) {
            try TrashPlan(group: photo, keep: fixture.realPath("win/pic.jpg"), trash: [copy])
        }
        #expect(throws: PlanError.wouldTrashKeptFile(keep)) {
            try TrashPlan(group: photo, keep: keep, trash: [copy, keep])
        }
        #expect(throws: PlanError.notInGroup(fixture.realPath("win/pic.jpg"))) {
            try TrashPlan(group: photo, keep: keep, trash: [fixture.realPath("win/pic.jpg")])
        }
        #expect(throws: PlanError.listedTwice) { try TrashPlan(group: photo, keep: keep, trash: [copy, copy]) }
        #expect(throws: PlanError.nothingToTrash) { try TrashPlan(group: photo, keep: keep, trash: []) }

        // Keeping one file trashes all the others: the group always keeps exactly one.
        let plan = try TrashPlan(group: photo, keeping: keep)
        #expect(plan.trash.count == photo.files.count - 1)
        #expect(!plan.trash.contains { $0.path == keep })

        // Hard links are never trashed, even on request.
        let linked = try fixture.group(result, containing: "hl2/a.jpg")
        #expect(throws: PlanError.hardLinked(fixture.realPath("hl2/a.jpg"))) {
            try TrashPlan(group: linked, keep: fixture.realPath("hl2/a copy.jpg"), trash: [fixture.realPath("hl2/a.jpg")])
        }
        // Keeping the copy leaves the hard-linked file alone, so there's nothing to trash.
        #expect(throws: PlanError.nothingToTrash) {
            try TrashPlan(group: linked, keeping: fixture.realPath("hl2/a copy.jpg"))
        }
    }

    @Test func nothingIsPreselectedInAmbiguousGroups() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.scan()
        var selection = CleanSelection()
        selection.acceptSuggestions(in: result.groups)
        for group in result.ambiguousGroups { #expect(selection.plan(for: group) == nil) }
        #expect(selection.plans(in: result.groups).count == result.autoResolvableGroups.count)

        let raw = try fixture.group(result, containing: "raw/IMG_9999.DNG")
        try selection.keep(fixture.realPath("raw/HBIK8661.DNG"), in: raw)
        #expect(selection.plan(for: raw)?.trash.map(\.path) == [fixture.realPath("raw/IMG_9999.DNG")])
        selection.skip(raw)
        #expect(selection.plan(for: raw) == nil)
    }

    // MARK: - A full session

    @Test func cleaningTheSuggestionsKeepsOneIntactFileInEveryGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.scan()
        var selection = CleanSelection()
        selection.acceptSuggestions(in: result.groups)
        let plans = selection.plans(in: result.groups)
        let before = try AuditTests.snapshot(fixture.root)

        let clean = try await fixture.cleaner(result).run(plans)

        let expectedTrash = Set(result.autoResolvableGroups.flatMap(\.suggestedForTrash).map(\.path))
        #expect(Set(clean.trashed.map(\.file.path)) == expectedTrash)
        #expect(clean.notMoved.isEmpty && !clean.cancelled && clean.notReached == 0 && clean.stopReason == nil)

        // Snapshots are keyed by the fixture's own path; the scan reports resolved paths.
        let key = { (resolved: String) in fixture.path(fixture.relative(resolved)) }
        let after = try AuditTests.snapshot(fixture.root)
        for group in result.groups {
            let kept = group.files.filter { after[key($0.path)] != nil }
            #expect(!kept.isEmpty, "group \(group.sha256) lost every file")
            for file in kept { #expect(after[key(file.path)] == before[key(file.path)], "kept file changed: \(file.path)") }
        }
        // Everything not trashed is exactly as it was; trashed files sit intact in the Trash.
        let trashedKeys = Set(expectedTrash.map(key))
        for (path, entry) in before where !trashedKeys.contains(path) && entry.type != S_IFDIR {
            #expect(after[path] == entry, "changed: \(path)")
        }
        for path in trashedKeys { #expect(after[path] == nil) }
        for outcome in clean.trashed {
            guard case let .trashed(trashPath?) = outcome.status else { Issue.record("no trash path"); continue }
            #expect(FileManager.default.contents(atPath: trashPath).map { AuditTests.sha($0) } == before[key(outcome.file.path)]?.content)
        }

        // The log: start, intent + trashed for each file, end; each entry fully described.
        let (entries, incomplete) = try SessionLog.read(clean.log.jsonl)
        #expect(!incomplete)
        #expect(entries.first?.event == .sessionStart && entries.first?.roots == result.roots.paths)
        #expect(entries.last?.event == .sessionEnd && entries.last?.trashedCount == expectedTrash.count)
        let trashedEntries = entries.filter { $0.event == .trashed }
        #expect(entries.filter { $0.event == .intent }.count == expectedTrash.count)
        #expect(trashedEntries.count == expectedTrash.count)
        for entry in trashedEntries {
            let plan = try #require(plans.first { $0.trash.contains { $0.path == entry.original } })
            #expect(entry.kept == plan.keep.path)
            #expect(entry.sha256 == plan.group.sha256)
            #expect(entry.size == plan.group.size)
            #expect(entry.trash?.hasPrefix(fixture.trashFolder.path) == true)
            #expect(entry.reason == nil)
        }
        let summary = try String(contentsOf: clean.log.summary, encoding: .utf8)
        #expect(summary.contains("Moved to the Trash: \(expectedTrash.count) files"))
        #expect(summary.contains("doppio restore"))
    }

    @Test func plansThatConflictOrReachOutsideAreRefusedUpFront() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.scan()
        let before = try AuditTests.snapshot(fixture.root)
        let plan = try fixture.plan(result, keep: "win/pic.jpg", trash: "win/pic - Copy.jpg")
        await #expect(throws: CleanError.self) { try await fixture.cleaner(result).run([plan, plan]) }

        // Swap roles: a second plan that trashes the first plan's kept file.
        let swapped = try fixture.plan(result, keep: "win/pic - Copy.jpg", trash: "win/pic.jpg")
        await #expect(throws: CleanError.self) { try await fixture.cleaner(result).run([plan, swapped]) }

        // A cleaner for a different folder may not touch these files.
        let other = try ScanRoots([fixture.outside])
        let foreign = Cleaner(roots: other, logDirectory: fixture.logFolder, mover: FolderTrash(folder: fixture.trashFolder))
        await #expect(throws: CleanError.outsideScannedFolders(path: fixture.realPath("win/pic - Copy.jpg"))) {
            try await foreign.run([plan])
        }
        #expect(try AuditTests.snapshot(fixture.root) == before)
    }

    // MARK: - Checks right before each file is trashed

    /// Runs one plan after `tamper` and returns the single outcome.
    func outcome(keep: String, trash: String, mover: (any TrashMover)? = nil,
                 tamper: (Fixture) throws -> Void) async throws -> (CleanOutcome, Fixture) {
        let fixture = try Fixture()
        let result = try await fixture.scan()
        let plan = try fixture.plan(result, keep: keep, trash: trash)
        try tamper(fixture)
        let clean = try await fixture.cleaner(result, mover: mover).run([plan])
        return (try #require(clean.outcomes.first), fixture)
    }

    @Test func keptFileMissing() async throws {
        let (o, fixture) = try await outcome(keep: "win/pic.jpg", trash: "win/pic - Copy.jpg") { try $0.moveAway("win/pic.jpg") }
        defer { fixture.cleanup() }
        #expect(o.status == .skipped(reason: SafetyRefusal.keptFileMissing(path: fixture.realPath("win/pic.jpg")).description))
        #expect(fixture.exists("win/pic - Copy.jpg"))
    }

    @Test func keptFileModified() async throws {
        let (o, fixture) = try await outcome(keep: "win/pic.jpg", trash: "win/pic - Copy.jpg") { f in
            let size = f.contents("win/pic.jpg")!.count
            try bytes(seed: 99, count: size).write(to: URL(fileURLWithPath: f.path("win/pic.jpg")))
        }
        defer { fixture.cleanup() }
        #expect(o.reason?.contains("the file being kept") == true && o.reason?.contains("changed since the scan") == true)
        #expect(fixture.exists("win/pic - Copy.jpg"))
    }

    @Test func keptFileContentChangedWithSameSizeAndMtime() async throws {
        // Size and mtime look untouched; only reading the bytes again can tell.
        let (o, fixture) = try await outcome(keep: "win/pic.jpg", trash: "win/pic - Copy.jpg") { f in
            try f.overwriteKeepingMtime("win/pic.jpg", with: bytes(seed: 98, count: f.contents("win/pic.jpg")!.count))
        }
        defer { fixture.cleanup() }
        #expect(o.status == .skipped(reason: SafetyRefusal.contentDiffers(
            path: fixture.realPath("win/pic - Copy.jpg"), kept: fixture.realPath("win/pic.jpg")).description))
        #expect(fixture.exists("win/pic - Copy.jpg"))
    }

    @Test func bothFilesChangedIdenticallySinceTheScan() async throws {
        let (o, fixture) = try await outcome(keep: "win/pic.jpg", trash: "win/pic - Copy.jpg") { f in
            let other = bytes(seed: 97, count: f.contents("win/pic.jpg")!.count)
            try f.overwriteKeepingMtime("win/pic.jpg", with: other)
            try f.overwriteKeepingMtime("win/pic - Copy.jpg", with: other)
        }
        defer { fixture.cleanup() }
        #expect(o.status == .skipped(reason: SafetyRefusal.contentChangedSinceScan(
            path: fixture.realPath("win/pic - Copy.jpg")).description))
        #expect(fixture.exists("win/pic - Copy.jpg"))
    }

    @Test func candidateModified() async throws {
        let (o, fixture) = try await outcome(keep: "win/pic.jpg", trash: "win/pic - Copy.jpg") { f in
            usleep(10_000)
            try f.contents("win/pic - Copy.jpg")!.write(to: URL(fileURLWithPath: f.path("win/pic - Copy.jpg")))
        }
        defer { fixture.cleanup() }
        #expect(o.reason?.contains("changed since the scan") == true)
        #expect(fixture.exists("win/pic - Copy.jpg"))
    }

    @Test func candidateGrewAHardLink() async throws {
        let (o, fixture) = try await outcome(keep: "win/pic.jpg", trash: "win/pic - Copy.jpg") { f in
            try FileManager.default.linkItem(atPath: f.path("win/pic - Copy.jpg"), toPath: f.outside.appendingPathComponent("link.jpg").path)
        }
        defer { fixture.cleanup() }
        #expect(o.status == .skipped(reason: SafetyRefusal.hardLinked(path: fixture.realPath("win/pic - Copy.jpg")).description))
        #expect(fixture.exists("win/pic - Copy.jpg"))
    }

    @Test func candidateReplacedBySymlink() async throws {
        let (o, fixture) = try await outcome(keep: "win/pic.jpg", trash: "win/pic - Copy.jpg") { f in
            try f.moveAway("win/pic - Copy.jpg")
            try FileManager.default.createSymbolicLink(atPath: f.path("win/pic - Copy.jpg"), withDestinationPath: "pic.jpg")
        }
        defer { fixture.cleanup() }
        #expect(o.status == .skipped(reason: SafetyRefusal.pathNowThroughSymlink(path: fixture.realPath("win/pic - Copy.jpg")).description))
        let st = try FileStat.lstat(fixture.realPath("win/pic - Copy.jpg"))
        #expect(st.isSymlink)
        #expect(fixture.exists("win/pic.jpg"))
    }

    @Test func folderSwappedForASymlinkToOutside() async throws {
        let (o, fixture) = try await outcome(keep: "mac/photo.jpg", trash: "mac/photo copy.jpg") { f in
            let away = f.outside.appendingPathComponent("mac-moved")
            try FileManager.default.moveItem(atPath: f.realPath("mac"), toPath: away.path)
            try FileManager.default.createSymbolicLink(atPath: f.path("mac"), withDestinationPath: away.path)
        }
        defer { fixture.cleanup() }
        #expect(o.status == .skipped(reason: SafetyRefusal.pathNowThroughSymlink(path: fixture.realPath("mac/photo copy.jpg")).description))
        #expect(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("mac-moved/photo copy.jpg").path))
    }

    @Test func volumeWithoutATrashIsReportedNeverDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.scan()
        var selection = CleanSelection()
        selection.acceptSuggestions(in: result.groups)
        let before = try AuditTests.snapshot(fixture.root)
        let clean = try await fixture.cleaner(result, mover: NoTrash()).run(selection.plans(in: result.groups))
        #expect(clean.trashed.isEmpty)
        #expect(!clean.outcomes.isEmpty && clean.outcomes.allSatisfy {
            if case .failed = $0.status { true } else { false }
        })
        #expect(try AuditTests.snapshot(fixture.root) == before)
        let entries = try SessionLog.read(clean.log.jsonl).entries
        #expect(entries.filter { $0.event == .failed }.count == clean.outcomes.count)
    }

    @Test func cancellingStopsBeforeTheNextFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.scan()
        var selection = CleanSelection()
        selection.acceptSuggestions(in: result.groups)
        let plans = selection.plans(in: result.groups)
        let holder = CleanTaskHolder()
        let mover = ObservedTrash(inner: FolderTrash(folder: fixture.trashFolder)) {
            while holder.task == nil { usleep(1_000) }
            holder.task?.cancel()
        }
        let task = Task { try await fixture.cleaner(result, mover: mover).run(plans) }
        holder.task = task
        let clean = try await task.value
        #expect(clean.cancelled)
        #expect(clean.trashed.count == 1)
        #expect(clean.notReached == plans.reduce(0) { $0 + $1.trash.count } - 1)
        let end = try #require(try SessionLog.read(clean.log.jsonl).entries.last)
        #expect(end.event == .sessionEnd && end.cancelled == true)
    }

    // MARK: - Location rules, checked directly

    @Test func onlyFilesInsideTheScannedFoldersAndOutsidePackages() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.scan()
        let photo = try fixture.group(result, containing: "mac/photo.jpg")
        let kept = try #require(photo.files.first { fixture.relative($0.path) == "mac/photo.jpg" })

        // Same bytes, but inside the (skipped) Photos library: never trashable.
        let inLibrary = fixture.realPath("Lib.photoslibrary/originals/A/photo.jpg")
        let libraryFile = DuplicateFile(record: FileRecord(path: inLibrary, stat: try FileStat.lstat(inLibrary)),
                                        hardLinkPaths: [], privateSize: nil, spaceIsExact: true)
        #expect(throws: SafetyRefusal.insidePackage(path: inLibrary)) {
            try SafetyGuard.check(libraryFile, keeping: kept, in: photo, roots: result.roots, cancel: CancelFlag())
        }

        // Same bytes, outside the scanned folder.
        let outsidePath = ScanRoots.realPath(fixture.outside.path)! + "/photo.jpg"
        try fixture.contents("mac/photo.jpg")!.write(to: URL(fileURLWithPath: outsidePath))
        let outsideFile = DuplicateFile(record: FileRecord(path: outsidePath, stat: try FileStat.lstat(outsidePath)),
                                        hardLinkPaths: [], privateSize: nil, spaceIsExact: true)
        #expect(throws: SafetyRefusal.outsideScannedFolders(path: outsidePath)) {
            try SafetyGuard.check(outsideFile, keeping: kept, in: photo, roots: result.roots, cancel: CancelFlag())
        }

        // And the normal case passes, returning the group's hash.
        let copy = try #require(photo.files.first { fixture.relative($0.path) == "mac/photo copy.jpg" })
        #expect(try SafetyGuard.check(copy, keeping: kept, in: photo, roots: result.roots, cancel: CancelFlag()) == photo.sha256)
        #expect(throws: SafetyRefusal.sameFileAsKept(path: kept.path)) {
            try SafetyGuard.check(kept, keeping: kept, in: photo, roots: result.roots, cancel: CancelFlag())
        }
    }

    // MARK: - Log files

    @Test func logsAreNeverReusedOrOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let date = Date()
        let first = try SessionLog(kind: "clean", directory: fixture.logFolder, date: date)
        try first.append(LogEntry(.sessionStart))
        let second = try SessionLog(kind: "clean", directory: fixture.logFolder, date: date)
        #expect(first.paths.jsonl != second.paths.jsonl)
        #expect(try SessionLog.read(first.paths.jsonl).entries.count == 1)
        try first.writeSummary("one")
        #expect(throws: LogError.self) { try first.writeSummary("two") }
        #expect(try String(contentsOf: first.paths.summary, encoding: .utf8) == "one")
    }
}

final class CleanTaskHolder: @unchecked Sendable {
    var task: Task<CleanResult, Error>?
}
