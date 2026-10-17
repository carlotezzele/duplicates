import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DoppioCore

struct RestoreTests {
    /// Cleans every suggested group into the fake Trash.
    func cleanAll(_ fixture: Fixture) async throws -> (ScanResult, CleanResult) {
        let result = try await fixture.scan()
        var selection = CleanSelection()
        selection.acceptSuggestions(in: result.groups)
        let clean = try await fixture.cleaner(result).run(selection.plans(in: result.groups))
        #expect(!clean.trashed.isEmpty)
        return (result, clean)
    }

    /// What must come back exactly: every path, and each file's inode, size, mtime and content.
    /// (Folder timestamps and file ctimes change when anything is moved, so they're left out.)
    func identity(_ root: URL) throws -> [String: String] {
        try AuditTests.snapshot(root).mapValues { e in
            e.type == S_IFDIR ? "dir" : "\(e.type) \(e.inode) \(e.size) \(e.mtime) \(e.content)"
        }
    }

    @Test func restoreBringsEverythingBack() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let before = try identity(fixture.root)
        let (_, clean) = try await cleanAll(fixture)
        #expect(try identity(fixture.root) != before)

        let plan = try Restorer.load(clean.log.jsonl)
        #expect(plan.items.count == clean.trashed.count)
        #expect(plan.problems.isEmpty)
        let restore = try await Restorer(logDirectory: fixture.logFolder).run(plan)
        #expect(restore.restored.count == clean.trashed.count)
        #expect(restore.skipped.isEmpty)
        #expect(try identity(fixture.root) == before)

        // The restore session is logged too.
        let entries = try SessionLog.read(restore.log.jsonl).entries
        #expect(entries.first?.command == "restore" && entries.first?.sourceLog == clean.log.jsonl.path)
        #expect(entries.filter { $0.event == .restored }.count == clean.trashed.count)

        // A second restore finds nothing to do and changes nothing.
        let again = try await Restorer(logDirectory: fixture.logFolder).run(plan)
        #expect(again.restored.isEmpty)
        #expect(again.skipped.allSatisfy { $0.status == .skipped(reason: "already back at its original location") })
        #expect(try identity(fixture.root) == before)
    }

    @Test func neverOverwritesAFileAtTheOriginalPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, clean) = try await cleanAll(fixture)
        let trashed = try #require(clean.trashed.first { fixture.relative($0.file.path) == "win/pic - Copy.jpg" })
        guard case let .trashed(trashPath?) = trashed.status else { Issue.record(); return }
        let newcomer = Data("a new, unrelated file".utf8)
        try newcomer.write(to: URL(fileURLWithPath: trashed.file.path))

        let plan = try Restorer.load(clean.log.jsonl)
        let item = try #require(plan.items.first { $0.original == trashed.file.path })
        #expect(Restorer.preflight(item) == "something else already exists at the original location")
        let restore = try await Restorer(logDirectory: fixture.logFolder).run(plan, only: [item])
        #expect(restore.restored.isEmpty)
        #expect(FileManager.default.contents(atPath: trashed.file.path) == newcomer)
        #expect(FileManager.default.fileExists(atPath: trashPath))
    }

    @Test func skipsWhenTheOriginalFolderIsGone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, clean) = try await cleanAll(fixture)
        try fixture.moveAway("export")
        let plan = try Restorer.load(clean.log.jsonl)
        let restore = try await Restorer(logDirectory: fixture.logFolder).run(plan)
        let inExport = restore.outcomes.filter { fixture.relative($0.item.original).hasPrefix("export/") }
        #expect(inExport.count == 2)
        #expect(inExport.allSatisfy { $0.status == .skipped(reason: "its original folder no longer exists") })
        #expect(!fixture.exists("export"))
        #expect(restore.restored.count == clean.trashed.count - 2)
        for outcome in inExport { #expect(FileManager.default.fileExists(atPath: outcome.item.trashPath)) }
    }

    @Test func skipsAFileThatChangedInTheTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, clean) = try await cleanAll(fixture)
        let plan = try Restorer.load(clean.log.jsonl)
        let item = try #require(plan.items.first { fixture.relative($0.original) == "win/pic - Copy.jpg" })
        // Same size and inode, different bytes.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: item.trashPath))
        try handle.write(contentsOf: bytes(seed: 77, count: Int(item.size)))
        try handle.close()
        let restore = try await Restorer(logDirectory: fixture.logFolder).run(plan, only: [item])
        #expect(restore.outcomes.map(\.status) == [.skipped(reason: "its content changed while in the Trash")])
        #expect(!fixture.exists("win/pic - Copy.jpg"))
    }

    @Test func interruptedAndDamagedLogs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, clean) = try await cleanAll(fixture)
        var text = try String(contentsOf: clean.log.jsonl, encoding: .utf8)

        // An intent with no outcome (crash while trashing) plus a torn last line.
        var intent = LogEntry(.intent)
        intent.original = "/somewhere/lost.jpg"
        text += String(decoding: try LogEntry.encoder.encode(intent), as: UTF8.self) + "\n" + #"{"event":"tras"#
        let torn = fixture.outside.appendingPathComponent("torn.jsonl")
        try text.write(to: torn, atomically: true, encoding: .utf8)
        let plan = try Restorer.load(torn)
        #expect(plan.items.count == clean.trashed.count)
        #expect(plan.problems.contains { $0.hasPrefix("/somewhere/lost.jpg: the session stopped") })
        #expect(plan.problems.contains { $0.contains("incomplete") })

        // A damaged line in the middle: refuse the whole log.
        var lines = try String(contentsOf: clean.log.jsonl, encoding: .utf8).components(separatedBy: "\n")
        lines[2] = "garbage"
        let damaged = fixture.outside.appendingPathComponent("damaged.jsonl")
        try lines.joined(separator: "\n").write(to: damaged, atomically: true, encoding: .utf8)
        #expect(throws: RestoreError.malformedLog(damaged.path, line: 3)) { try Restorer.load(damaged) }

        // A restore log (or anything else) is not something to restore from.
        let restore = try await Restorer(logDirectory: fixture.logFolder).run(try Restorer.load(clean.log.jsonl))
        #expect(throws: RestoreError.notACleanLog(restore.log.jsonl.path)) { try Restorer.load(restore.log.jsonl) }
    }
}

/// One round trip through the real Trash with a tiny, clearly named file.
/// It is restored at the end, so the Trash is left as it was.
struct RealTrashTests {
    @Test func trashAndRestoreWithTheSystemTrash() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("doppio-real-trash-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("photos")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "doppio-test-\(UUID().uuidString.prefix(8))"
        let data = Data("Doppio test file; safe to delete.".utf8)
        try data.write(to: folder.appendingPathComponent("\(name).jpg"))
        try data.write(to: folder.appendingPathComponent("\(name) copy.jpg"))

        let result = try await DuplicateFinder(options: ScanOptions(roots: [folder])).run()
        let plan = try #require(result.groups.first.flatMap(TrashPlan.suggested))
        let clean = try await Cleaner(roots: result.roots, logDirectory: base.appendingPathComponent("logs")).run([plan])
        let outcome = try #require(clean.outcomes.first)
        guard case let .trashed(trashPath?) = outcome.status else {
            Issue.record("not trashed: \(outcome.status)")
            return
        }
        #expect(trashPath.contains("/.Trash"))
        #expect(!FileManager.default.fileExists(atPath: outcome.file.path))

        let restore = try await Restorer(logDirectory: base.appendingPathComponent("logs")).run(try Restorer.load(clean.log.jsonl))
        #expect(restore.restored.count == 1)
        #expect(FileManager.default.contents(atPath: outcome.file.path) == data)
        #expect(!FileManager.default.fileExists(atPath: trashPath))
    }
}

struct CaptureDateTests {
    @Test func readsExifDateTimeOriginal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doppio-exif-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:21:33",
                                     kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let date = await CaptureDate.read(path: url.path)
        #expect(date == ISO8601DateFormatter().date(from: "2024-05-01T08:21:33Z"))
    }

    @Test func noMetadataMeansNoDate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doppio-nodate-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try bytes(seed: 5, count: 1000).write(to: url)
        #expect(await CaptureDate.read(path: url.path) == nil)
        #expect(await CaptureDate.read(path: url.deletingPathExtension().appendingPathExtension("jpg").path) == nil)
    }

    @Test func exifWithoutOffsetIsLocalTime() {
        var components = DateComponents(year: 2023, month: 12, day: 31, hour: 23, minute: 59, second: 1)
        components.timeZone = .current
        #expect(CaptureDate.parseExif("2023:12:31 23:59:01", offset: nil) == Calendar.current.date(from: components))
        #expect(CaptureDate.parseExif("not a date", offset: nil) == nil)
    }
}
