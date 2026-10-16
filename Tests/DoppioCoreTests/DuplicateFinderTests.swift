import Darwin
import Foundation
import Testing
@testable import DoppioCore

struct DuplicateFinderTests {
    func scan(_ fixture: Fixture, allTypes: Bool = false, jobs: Int = 1,
              roots: [URL]? = nil) async throws -> ScanResult {
        try await DuplicateFinder(options: ScanOptions(roots: roots ?? [fixture.root],
                                                       includeAllTypes: allTypes, jobs: jobs)).run()
    }

    func summarize(_ result: ScanResult, _ fixture: Fixture) -> [Set<String>: String?] {
        var out: [Set<String>: String?] = [:]
        for group in result.groups {
            // updateValue, not subscript: assigning nil through a subscript would delete the key.
            out.updateValue(group.suggestion.keptPath.map(fixture.relative),
                            forKey: Set(group.files.map { fixture.relative($0.path) }))
        }
        return out
    }

    @Test func findsExactlyTheExpectedGroups() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await scan(fixture)
        let found = summarize(result, fixture)
        #expect(found == Fixture.expectedGroups)
        #expect(result.autoResolvableGroups.count == 14)
        #expect(result.ambiguousGroups.count == 2)
    }

    @Test func allTypesAddsNonMediaFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let found = summarize(try await scan(fixture, allTypes: true), fixture)
        #expect(found == Fixture.expectedGroups.merging(Fixture.allTypesExtraGroups) { a, _ in a })
    }

    @Test func parallelismDoesNotChangeTheResult() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let one = try await scan(fixture, jobs: 1)
        let four = try await scan(fixture, jobs: 4)
        #expect(one.groups == four.groups)
        #expect(one.issues == four.issues)
    }

    @Test func unreadableFilesAndFoldersAreReportedNotGuessed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await scan(fixture)
        let issues = Dictionary(uniqueKeysWithValues: result.issues.map { (fixture.relative($0.path), $0.kind) })
        #expect(issues["locked/secret.mp4"] == .unreadableFile)
        #expect(issues["lockeddir"] == .unreadableFolder)
        let grouped = Set(result.groups.flatMap(\.files).map { fixture.relative($0.path) })
        #expect(!grouped.contains("locked/secret.mp4"))
    }

    @Test func skipsWhatMustBeSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await scan(fixture)
        let everyPath = result.groups.flatMap(\.files).flatMap(\.allPaths).map { fixture.relative($0) }
        #expect(!everyPath.contains { $0.contains("photoslibrary") })
        #expect(!everyPath.contains { $0.contains(".Trashes") })
        #expect(!everyPath.contains { $0.hasPrefix("sym/") })
        #expect(!everyPath.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") })
        #expect(!everyPath.contains { $0.hasPrefix("empty/") })
        #expect(result.skipped.symlinks == 2)
        #expect(result.skipped.zeroByte == 2)
        #expect(result.skipped.packages == 1)
        #expect(result.skipped.systemFolders == 1)
        #expect(result.skipped.metadataFiles == 4) // 2 AppleDouble + 2 .DS_Store
    }

    @Test func hardLinksAreOneFileAndNeverTrashable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await scan(fixture)
        let all = result.groups.flatMap(\.files)
        #expect(!all.contains { fixture.relative($0.path).hasPrefix("hl/") })

        let group = try #require(result.groups.first { $0.files.contains { fixture.relative($0.path) == "hl2/a.jpg" } })
        #expect(group.files.count == 2) // hl2/a.jpg + hl2/a_link.jpg count as one
        let linked = try #require(group.files.first { fixture.relative($0.path) == "hl2/a.jpg" })
        #expect(linked.hardLinkPaths.map(fixture.relative) == ["hl2/a_link.jpg"])
        #expect(!linked.canBeTrashed)
        #expect(linked.reclaimableSize == 0)
        #expect(group.suggestedForTrash.map { fixture.relative($0.path) } == ["hl2/a copy.jpg"])
    }

    @Test func apfsClonesFreeLessThanTheirSize() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try #require(SpaceInfo.fileSystemType(path: fixture.root.path) == "apfs")
        let result = try await scan(fixture)
        let group = try #require(result.groups.first { $0.files.contains { fixture.relative($0.path) == "clone/vacation.jpg" } })
        #expect(group.size == 500_000)
        #expect(group.files.allSatisfy { $0.privateSize != nil })
        #expect(group.reclaimableSize < group.size / 10)
        #expect(group.spaceIsExact)
    }

    @Test func nestedAndRepeatedRootsAreScannedOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let plain = try await scan(fixture)
        let nested = try await scan(fixture, roots: [fixture.root, fixture.root.appendingPathComponent("mac"), fixture.root])
        #expect(plain.groups == nested.groups)
        #expect(nested.roots.paths.count == 1)
    }

    @Test func refusesPackagesAndMissingFoldersAsRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let library = fixture.root.appendingPathComponent("Lib.photoslibrary/originals")
        await #expect(throws: ScanError.self) { try await scan(fixture, roots: [library]) }
        await #expect(throws: ScanError.self) { try await scan(fixture, roots: [fixture.root.appendingPathComponent("nope")]) }
    }

    @Test func cancellationStopsTheScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let holder = TaskHolder()
        let task = Task {
            try await DuplicateFinder(options: ScanOptions(roots: [fixture.root])).run { progress in
                guard progress.phase == .fullHash else { return }
                while holder.task == nil { usleep(1_000) }
                holder.task?.cancel()
            }
        }
        holder.task = task
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: - Byte-by-byte confirmation

    @Test func sameHashButDifferentBytesIsNotADuplicate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // Pretend near/mid_a and near/mid_b had the same hash: verification must catch it.
        let a = try record(fixture, "near/mid_a.mov")
        let b = try record(fixture, "near/mid_b.mov")
        let outcome = DuplicateFinder.verify([a, b], cancel: CancelFlag()) { _ in }
        #expect(outcome.confirmed.count <= 1)
        #expect(outcome.issues.map(\.kind) == [.contentMismatch])
    }

    @Test func fileChangedAfterListingIsReported() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let a = try record(fixture, "win/pic.jpg")
        let b = try record(fixture, "win/pic - Copy.jpg")
        // Rewrite b with identical bytes: same content, but it's no longer the scanned file.
        let data = try Data(contentsOf: URL(fileURLWithPath: b.path))
        usleep(10_000)
        try data.write(to: URL(fileURLWithPath: b.path))
        let outcome = DuplicateFinder.verify([a, b], cancel: CancelFlag()) { _ in }
        #expect(outcome.confirmed.count <= 1)
        #expect(outcome.issues.map(\.kind) == [.changedDuringScan])
    }

    @Test func unreadableReferenceFallsBackToNextFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let locked = try record(fixture, "locked/secret.mp4")
        let a = try record(fixture, "phone/VID_20250822_205114.mp4")
        let b = try record(fixture, "phone/VID_20250822_205114_1.mp4")
        let outcome = DuplicateFinder.verify([locked, a, b], cancel: CancelFlag()) { _ in }
        #expect(outcome.confirmed.map(\.path) == [a.path, b.path])
        #expect(outcome.issues.map(\.kind) == [.unreadableFile])
    }

    func record(_ fixture: Fixture, _ relative: String) throws -> FileRecord {
        let path = fixture.realPath(relative)
        return FileRecord(path: path, stat: try FileStat.lstat(path))
    }
}

final class TaskHolder: @unchecked Sendable {
    var task: Task<ScanResult, Error>?
}
