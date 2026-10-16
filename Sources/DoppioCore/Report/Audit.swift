import Foundation

/// Read-only audit: scan, then write the report. Nothing in the scanned folders is
/// modified: files are only opened O_RDONLY, no xattrs or caches are written there,
/// and the report destination is refused if it lies inside a scanned folder.
public enum Audit {
    public static func run(
        _ options: ScanOptions,
        reportDestination: URL?,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> (result: ScanResult, report: AuditReport.Paths) {
        let roots = try ScanRoots(options.roots)
        let paths = AuditReport.paths(for: reportDestination, startedAt: Date())
        try AuditReport.validate(paths, roots: roots)
        let result = try await DuplicateFinder(options: options).run(progress: progress)
        try AuditReport.write(result, to: paths)
        return (result, paths)
    }
}
