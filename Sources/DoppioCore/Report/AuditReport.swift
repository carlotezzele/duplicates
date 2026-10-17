import Foundation

/// Writes the read-only audit report (JSON + CSV) and the console summary.
public enum AuditReport {
    public struct Paths: Sendable, Equatable {
        public let json: URL
        public let csv: URL
    }

    public enum ReportError: Error, CustomStringConvertible {
        case insideScannedFolder(String)
        case cannotWrite(String, String)

        public var description: String {
            switch self {
            case let .insideScannedFolder(path):
                "The report would be written inside a scanned folder (\(path)). Audit never writes there; choose another --report location."
            case let .cannotWrite(path, reason): "Cannot write report \(path): \(reason)"
            }
        }
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Doppio/Reports", isDirectory: true)
    }

    /// `destination` may be nil (default folder), a file path ending in .json or .csv
    /// (both files are written side by side), or any other path, taken as a folder.
    public static func paths(for destination: URL?, startedAt: Date) -> Paths {
        let name = "doppio-audit-\(fileTimestamp(startedAt))"
        let base: URL
        if let destination {
            let ext = destination.pathExtension.lowercased()
            if ext == "json" || ext == "csv" {
                base = destination.deletingPathExtension()
            } else {
                base = destination.appendingPathComponent(name)
            }
        } else {
            base = defaultDirectory.appendingPathComponent(name)
        }
        return Paths(json: base.appendingPathExtension("json"), csv: base.appendingPathExtension("csv"))
    }

    /// Refuses destinations inside the scanned folders, before anything is scanned.
    public static func validate(_ paths: Paths, roots: ScanRoots) throws {
        for url in [paths.json, paths.csv] {
            let folder = url.deletingLastPathComponent().standardizedFileURL.path
            // Resolve the deepest existing ancestor so symlinked destinations are caught too.
            var probe = folder
            while ScanRoots.realPath(probe) == nil && probe != "/" {
                probe = (probe as NSString).deletingLastPathComponent
            }
            let resolved = (ScanRoots.realPath(probe) ?? probe) + String(folder.dropFirst(probe.count))
            if roots.paths.contains(where: { ScanRoots.isPath(resolved, inside: $0) }) {
                throw ReportError.insideScannedFolder(url.path)
            }
        }
    }

    public static func write(_ result: ScanResult, to paths: Paths) throws {
        let folder = paths.json.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json(result).write(to: paths.json, options: .atomic)
            try Data(csv(result).utf8).write(to: paths.csv, options: .atomic)
        } catch {
            throw ReportError.cannotWrite(folder.path, error.localizedDescription)
        }
    }

    // MARK: - JSON

    struct JSONReport: Codable {
        struct Options: Codable { var allTypes: Bool; var jobs: Int; var randomNamesAreCopies: Bool }
        struct Summary: Codable {
            var groups: Int
            var autoResolvableGroups: Int
            var ambiguousGroups: Int
            var redundantFiles: Int
            var redundantBytes: Int64
            var reclaimableBytes: Int64
            var reclaimableIsUpperBound: Bool
            var filesConsidered: Int
            var issues: Int
        }
        struct File: Codable {
            var path: String
            var hardLinkPaths: [String]
            var size: Int64
            var created: String
            var modified: String
            var device: Int32
            var inode: UInt64
            var linkCount: Int
            var privateSize: Int64?
            var suggestion: String // keep | trash | review
        }
        struct Group: Codable {
            var sha256: String
            var size: Int64
            var suggestedKeep: String // a path, or "ambiguous"
            var ambiguousReason: String?
            var reclaimableBytes: Int64
            var files: [File]
        }
        var tool = "doppio"
        var version = Doppio.version
        var mode = "audit (read-only)"
        var createdAt: String
        var startedAt: String
        var roots: [String]
        var options: Options
        var summary: Summary
        var skipped: SkipStats
        var issues: [ScanIssue]
        var groups: [Group]
    }

    static func json(_ r: ScanResult) throws -> Data {
        let report = JSONReport(
            createdAt: iso(r.finishedAt), startedAt: iso(r.startedAt), roots: r.roots.paths,
            options: .init(allTypes: r.options.includeAllTypes, jobs: r.options.jobs,
                           randomNamesAreCopies: r.options.suggestionRules.randomNamesAreCopies),
            summary: .init(groups: r.groups.count, autoResolvableGroups: r.autoResolvableGroups.count,
                           ambiguousGroups: r.ambiguousGroups.count, redundantFiles: r.redundantFileCount,
                           redundantBytes: r.redundantBytes, reclaimableBytes: r.reclaimableBytes,
                           reclaimableIsUpperBound: !r.reclaimableIsExact,
                           filesConsidered: r.filesConsidered, issues: r.issues.count),
            skipped: r.skipped, issues: r.issues,
            groups: r.groups.map { group in
                JSONReport.Group(
                    sha256: group.sha256, size: group.size,
                    suggestedKeep: group.suggestion.keptPath ?? "ambiguous",
                    ambiguousReason: { if case let .ambiguous(reason) = group.suggestion { reason } else { nil } }(),
                    reclaimableBytes: group.reclaimableSize,
                    files: group.files.map { f in
                        JSONReport.File(path: f.path, hardLinkPaths: f.hardLinkPaths, size: f.record.size,
                                        created: iso(f.record.created.date), modified: iso(f.record.modified.date),
                                        device: f.record.device, inode: f.record.inode,
                                        linkCount: Int(f.record.linkCount), privateSize: f.privateSize,
                                        suggestion: role(of: f, in: group))
                    })
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    // MARK: - CSV

    public static let csvHeader = [
        "group_sha256", "size_bytes", "suggestion", "path", "suggested_keep",
        "created", "modified", "hard_link_count", "other_hard_link_paths",
    ]

    static func csv(_ r: ScanResult) -> String {
        var lines = [csvHeader.map(csvField).joined(separator: ",")]
        for group in r.groups {
            for f in group.files {
                lines.append([
                    group.sha256, String(group.size), role(of: f, in: group), f.path,
                    group.suggestion.keptPath ?? "ambiguous",
                    iso(f.record.created.date), iso(f.record.modified.date),
                    String(f.record.linkCount), f.hardLinkPaths.joined(separator: " | "),
                ].map(csvField).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180: every field quoted, quotes doubled (file names may contain commas,
    /// quotes or even newlines).
    static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func role(of file: DuplicateFile, in group: DuplicateGroup) -> String {
        guard let kept = group.suggestion.keptPath else { return "review" }
        return file.path == kept ? "keep" : "trash"
    }

    // MARK: - Console

    public static func consoleSummary(_ r: ScanResult) -> String {
        var out: [String] = []
        let seconds = r.finishedAt.timeIntervalSince(r.startedAt)
        out.append("Scanned \(r.roots.paths.count) folder(s): \(r.filesConsidered) \(r.options.includeAllTypes ? "files" : "photos/videos") considered in \(String(format: "%.1f", seconds)) s")
        if r.groups.isEmpty {
            out.append("No exact duplicates found.")
        } else {
            out.append("Duplicate groups:     \(r.groups.count)  (\(r.autoResolvableGroups.count) auto-resolvable, \(r.ambiguousGroups.count) need your choice)")
            out.append("Redundant copies:     \(r.redundantFileCount) files, \(formatBytes(r.redundantBytes))")
            out.append("Reclaimable space:    \(r.reclaimableIsExact ? "" : "up to ")\(formatBytes(r.reclaimableBytes))")
            let auto = r.autoResolvableGroups
            out.append("  of which automatic: \(auto.reduce(0) { $0 + $1.suggestedForTrash.count }) files, \(formatBytes(auto.reduce(0) { $0 + $1.reclaimableSize }))")
        }
        if !r.skipped.lines.isEmpty {
            out.append("Skipped:")
            for (label, count) in r.skipped.lines { out.append("  \(count) \(label)") }
        }
        if !r.issues.isEmpty {
            let byKind = Dictionary(grouping: r.issues, by: \.kind)
            out.append("Problems (\(r.issues.count), never treated as unique or duplicate):")
            for kind in byKind.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                out.append("  \(byKind[kind]!.count) \(kind.rawValue.replacingOccurrences(of: "_", with: " "))")
            }
        }
        return out.joined(separator: "\n")
    }
}

public enum Doppio {
    public static let version = "0.3.0"
}

public func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
    return formatter.string(fromByteCount: bytes)
}

func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

func fileTimestamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: date)
}
