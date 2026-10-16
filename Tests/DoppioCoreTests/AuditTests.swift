import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DoppioCore

struct AuditTests {
    /// Everything observable about a tree, including inside packages and through
    /// unreadable entries (as far as lstat allows). atime is excluded on purpose:
    /// reading a file may update it, and that is not a modification.
    struct Entry: Hashable, CustomStringConvertible {
        var path: String
        var type: UInt16
        var mode: UInt16
        var size: Int64
        var inode: UInt64
        var links: UInt16
        var mtime: Timestamp
        var ctime: Timestamp
        var flags: UInt32
        var xattrs: [String]
        var content: String // SHA-256, symlink target, or a marker
        var description: String { "\(path) size=\(size) mtime=\(mtime) ctime=\(ctime) xattrs=\(xattrs) content=\(content.prefix(12))" }
    }

    static func snapshot(_ root: URL) throws -> [String: Entry] {
        var out: [String: Entry] = [:]
        var stack = [root.path]
        while let dir = stack.popLast() {
            let names = (try? Walker.listDirectory(dir)) ?? ["<unlistable>"]
            for name in names {
                let path = dir + "/" + name
                guard let st = try? FileStat.lstat(path) else {
                    out[path] = Entry(path: path, type: 0, mode: 0, size: 0, inode: 0, links: 0,
                                      mtime: .init(seconds: 0, nanoseconds: 0), ctime: .init(seconds: 0, nanoseconds: 0),
                                      flags: 0, xattrs: [], content: "<no stat>")
                    continue
                }
                var content = ""
                if st.isRegular {
                    if let data = FileManager.default.contents(atPath: path) {
                        content = SHA256.hash(data: data).hexString
                    } else {
                        content = "<unreadable>"
                    }
                } else if st.isSymlink {
                    content = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "<bad link>"
                } else if st.isDirectory {
                    stack.append(path)
                }
                out[path] = Entry(path: path, type: st.fileType, mode: st.mode, size: st.size, inode: st.inode,
                                  links: st.linkCount, mtime: st.modified, ctime: st.changed, flags: st.flags,
                                  xattrs: xattrNames(path), content: content)
            }
        }
        if let st = try? FileStat.lstat(root.path) {
            out[root.path] = Entry(path: root.path, type: st.fileType, mode: st.mode, size: st.size, inode: st.inode,
                                   links: st.linkCount, mtime: st.modified, ctime: st.changed, flags: st.flags,
                                   xattrs: xattrNames(root.path), content: "<root>")
        }
        return out
    }

    static func xattrNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) == size else { return ["<error>"] }
        return buffer.split(separator: 0).map { String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self) }.sorted()
    }

    @Test func auditIsStrictlyReadOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let before = try Self.snapshot(fixture.root)
        #expect(before.count > 40)

        for allTypes in [false, true] {
            let options = ScanOptions(roots: [fixture.root], includeAllTypes: allTypes, jobs: 2)
            let (result, paths) = try await Audit.run(options, reportDestination: fixture.outside)
            #expect(!result.groups.isEmpty)
            #expect(FileManager.default.fileExists(atPath: paths.json.path))
            #expect(FileManager.default.fileExists(atPath: paths.csv.path))
            #expect(paths.json.path.hasPrefix(fixture.outside.path))
        }

        let after = try Self.snapshot(fixture.root)
        #expect(Set(after.keys) == Set(before.keys))
        for (path, entry) in before {
            #expect(after[path] == entry, "changed: \(path)")
        }
    }

    @Test func auditRefusesToWriteTheReportInsideAScannedFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let before = try Self.snapshot(fixture.root)
        for destination in [fixture.root, fixture.root.appendingPathComponent("mac/report.json"),
                            fixture.root.appendingPathComponent("new/folder/report.json")] {
            await #expect(throws: AuditReport.ReportError.self) {
                _ = try await Audit.run(ScanOptions(roots: [fixture.root]), reportDestination: destination)
            }
        }
        // Through a symlink pointing into the scanned folder, too.
        let link = fixture.outside.appendingPathComponent("sneaky")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.root.path)
        await #expect(throws: AuditReport.ReportError.self) {
            _ = try await Audit.run(ScanOptions(roots: [fixture.root]), reportDestination: link.appendingPathComponent("r.json"))
        }
        #expect(try Self.snapshot(fixture.root) == before)
    }

    @Test func reportContentsMatchTheScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (result, paths) = try await Audit.run(ScanOptions(roots: [fixture.root]),
                                                  reportDestination: fixture.outside.appendingPathComponent("r.json"))
        #expect(paths.json.lastPathComponent == "r.json")
        #expect(paths.csv.lastPathComponent == "r.csv")

        let report = try JSONDecoder().decode(AuditReport.JSONReport.self, from: Data(contentsOf: paths.json))
        #expect(report.summary.groups == result.groups.count)
        #expect(report.summary.autoResolvableGroups == 15)
        #expect(report.summary.ambiguousGroups == 3)
        #expect(report.groups.filter { $0.suggestedKeep == "ambiguous" }.count == 3)
        #expect(report.groups.flatMap(\.files).allSatisfy { ["keep", "trash", "review"].contains($0.suggestion) })
        #expect(report.issues.count == result.issues.count)

        let csv = try String(contentsOf: paths.csv, encoding: .utf8)
        let rows = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(rows.count == 1 + result.groups.reduce(0) { $0 + $1.files.count })
        #expect(rows[0].hasPrefix("\"group_sha256\""))
    }

    @Test func reportDestinationForms() {
        let date = Date(timeIntervalSince1970: 0)
        let file = AuditReport.paths(for: URL(fileURLWithPath: "/tmp/x/report.csv"), startedAt: date)
        #expect(file.json.path == "/tmp/x/report.json" && file.csv.path == "/tmp/x/report.csv")
        let folder = AuditReport.paths(for: URL(fileURLWithPath: "/tmp/not-yet-created"), startedAt: date)
        #expect(folder.json.deletingLastPathComponent().path == "/tmp/not-yet-created")
        #expect(folder.json.lastPathComponent.hasPrefix("doppio-audit-"))
        let byDefault = AuditReport.paths(for: nil, startedAt: date)
        #expect(byDefault.json.path.hasSuffix("Library/Logs/Doppio/Reports/" + byDefault.json.lastPathComponent))
    }

    @Test(arguments: [
        ("plain", "\"plain\""),
        ("with, comma", "\"with, comma\""),
        ("say \"hi\"", "\"say \"\"hi\"\"\""),
        ("two\nlines", "\"two\nlines\""),
    ])
    func csvFieldsAreQuoted(_ input: String, _ expected: String) {
        #expect(AuditReport.csvField(input) == expected)
    }

    @Test func consoleSummaryMentionsTheEssentials() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await DuplicateFinder(options: ScanOptions(roots: [fixture.root])).run()
        let text = AuditReport.consoleSummary(result)
        #expect(text.contains("Duplicate groups:     18"))
        #expect(text.contains("15 auto-resolvable, 3 need your choice"))
        #expect(text.contains("unreadable file"))
    }
}
