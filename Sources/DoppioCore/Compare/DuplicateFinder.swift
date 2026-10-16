import Foundation

public struct ScanResult: Sendable {
    public let roots: ScanRoots
    public let options: ScanOptions
    /// Largest reclaimable space first.
    public let groups: [DuplicateGroup]
    public let issues: [ScanIssue]
    public let skipped: SkipStats
    public let filesConsidered: Int
    public let startedAt: Date
    public let finishedAt: Date

    public var autoResolvableGroups: [DuplicateGroup] { groups.filter(\.suggestion.isAutoResolvable) }
    public var ambiguousGroups: [DuplicateGroup] { groups.filter { !$0.suggestion.isAutoResolvable } }
    public var redundantFileCount: Int { groups.reduce(0) { $0 + $1.files.count - 1 } }
    public var redundantBytes: Int64 { groups.reduce(0) { $0 + $1.size * Int64($1.files.count - 1) } }
    public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableSize } }
    public var reclaimableIsExact: Bool { groups.allSatisfy(\.spaceIsExact) }
}

/// Finds files with 100% identical content:
/// size → quick hash (first + last 64 KB) → full SHA-256 → byte-by-byte comparison.
/// Never looks at names to decide whether files are duplicates.
public struct DuplicateFinder: Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions) {
        self.options = options
    }

    /// Cancel the surrounding Task to stop; throws `CancellationError`.
    public func run(progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanResult {
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await pipeline(cancel: cancel, tracker: ProgressTracker(handler: progress))
        } onCancel: {
            cancel.cancel()
        }
    }

    private func pipeline(cancel: CancelFlag, tracker: ProgressTracker) async throws -> ScanResult {
        let started = Date()
        let roots = try ScanRoots(options.roots)
        IOPolicy.disableDatalessMaterialization()
        let jobs = options.jobs

        // 1. Walk.
        tracker.start(.walking)
        let walker = Walker(roots: roots, includeAllTypes: options.includeAllTypes, cancel: cancel)
        let walked = try await Blocking.run {
            do {
                return try walker.walk { _ in tracker.add(files: 1) }
            } catch {
                throw CancellationError() // the walker only throws when cancelled
            }
        }
        var issues = walked.issues

        // 2. One entry per physical file (hard links collapse), then group by exact size.
        let physical = Dictionary(grouping: walked.records, by: \.inodeKey).values.map { records in
            records.sorted { $0.path < $1.path }
        }
        let primaryByKey = Dictionary(uniqueKeysWithValues: physical.map { ($0[0].inodeKey, $0) })
        var candidates = Dictionary(grouping: physical.map { $0[0] }, by: \.size)
            .values.filter { $0.count > 1 }

        // 3. Quick hash for files big enough for it to save work.
        let needQuick = candidates.filter { $0[0].size > ContentHasher.quickCheckThreshold }.flatMap { $0 }
        tracker.start(.quickHash, filesTotal: needQuick.count,
                      bytesTotal: Int64(needQuick.count * ContentHasher.edgeSize * 2))
        let quick = try await Blocking.map(needQuick, jobs: jobs) { record -> Result<String, FileAccessError> in
            defer { tracker.add(files: 1, bytes: Int64(ContentHasher.edgeSize * 2)) }
            return Result { () throws(FileAccessError) in try ContentHasher.quickHash(record, cancel: cancel) }
        }
        try checkCancelled(cancel)
        var quickByPath: [String: String] = [:]
        for (record, result) in zip(needQuick, quick) {
            switch result {
            case let .success(hash): quickByPath[record.path] = hash
            case let .failure(error): issues.append(ScanIssue(error, fallbackPath: record.path))
            }
        }
        candidates = candidates.flatMap { group -> [[FileRecord]] in
            guard group[0].size > ContentHasher.quickCheckThreshold else { return [group] }
            return Dictionary(grouping: group.filter { quickByPath[$0.path] != nil }) { quickByPath[$0.path]! }
                .values.filter { $0.count > 1 }
        }

        // 4. Full SHA-256.
        let needFull = candidates.flatMap { $0 }
        tracker.start(.fullHash, filesTotal: needFull.count, bytesTotal: needFull.reduce(0) { $0 + $1.size })
        let full = try await Blocking.map(needFull, jobs: jobs) { record -> Result<String, FileAccessError> in
            defer { tracker.add(files: 1) }
            return Result { () throws(FileAccessError) in
                try ContentHasher.fullHash(record, cancel: cancel) { tracker.add(bytes: Int64($0)) }
            }
        }
        try checkCancelled(cancel)
        var hashed: [HashKey: [FileRecord]] = [:]
        for (record, result) in zip(needFull, full) {
            switch result {
            case let .success(hash): hashed[HashKey(size: record.size, sha256: hash), default: []].append(record)
            case let .failure(error): issues.append(ScanIssue(error, fallbackPath: record.path))
            }
        }
        let hashGroups = hashed.filter { $0.value.count > 1 }
            .map { (key: $0.key, records: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.key.sha256 < $1.key.sha256 }

        // 5. Byte-by-byte confirmation against the group's reference file.
        let verifyBytes = hashGroups.reduce(Int64(0)) { $0 + $1.key.size * 2 * Int64($1.records.count - 1) }
        tracker.start(.verifying, filesTotal: hashGroups.count, bytesTotal: verifyBytes)
        let verified = try await Blocking.map(hashGroups, jobs: jobs) { group in
            defer { tracker.add(files: 1) }
            return Self.verify(group.records, cancel: cancel) { tracker.add(bytes: Int64($0)) }
        }
        try checkCancelled(cancel)

        // 6. Space accounting and suggestions.
        tracker.start(.finishing, filesTotal: verified.count)
        var fsTypes: [Int32: String] = [:]
        var groups: [DuplicateGroup] = []
        for (group, outcome) in zip(hashGroups, verified) {
            issues += outcome.issues
            guard outcome.confirmed.count > 1 else { continue }
            let files = outcome.confirmed.map { record -> DuplicateFile in
                let links = primaryByKey[record.inodeKey] ?? [record]
                let privateSize = SpaceInfo.privateSize(path: record.path)
                if fsTypes[record.device] == nil {
                    fsTypes[record.device] = SpaceInfo.fileSystemType(path: record.path) ?? "unknown"
                }
                // Only APFS has clones; elsewhere allocated size is exactly what is freed.
                let exact = privateSize != nil || fsTypes[record.device] != "apfs"
                return DuplicateFile(record: record, hardLinkPaths: links.dropFirst().map(\.path),
                                     privateSize: privateSize, spaceIsExact: exact)
            }
            groups.append(DuplicateGroup(sha256: group.key.sha256, size: group.key.size, files: files,
                                         suggestion: Suggester.suggest(for: files, rules: options.suggestionRules)))
            tracker.add(files: 1)
        }
        tracker.finish()

        groups.sort { ($0.reclaimableSize, $1.files[0].path) > ($1.reclaimableSize, $0.files[0].path) }
        issues.sort { ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue) }
        return ScanResult(roots: roots, options: options, groups: groups, issues: issues,
                          skipped: walked.skipped, filesConsidered: walked.records.count,
                          startedAt: started, finishedAt: Date())
    }

    private func checkCancelled(_ cancel: CancelFlag) throws {
        if cancel.isCancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    struct VerifyOutcome: Sendable {
        var confirmed: [FileRecord] = []
        var issues: [ScanIssue] = []
    }

    /// Compares every file in a same-hash group with a reference file, byte by byte.
    /// A file that can't be read, has changed, or differs is reported and dropped.
    static func verify(_ records: [FileRecord], cancel: CancelFlag,
                       onBytes: (Int) -> Void) -> VerifyOutcome {
        var outcome = VerifyOutcome()
        var excluded = Set<String>() // failed or mismatched: never retried, never reported twice
        var remaining = records[...]
        while let reference = remaining.first {
            remaining = remaining.dropFirst()
            if excluded.contains(reference.path) { continue }
            var referenceFailed = false
            var confirmed = [reference]
            for candidate in remaining where !excluded.contains(candidate.path) {
                if cancel.isCancelled { return outcome }
                do {
                    if try ByteComparer.identical(reference, candidate, cancel: cancel, onBytes: onBytes) {
                        confirmed.append(candidate)
                    } else {
                        excluded.insert(candidate.path)
                        outcome.issues.append(ScanIssue(
                            kind: .contentMismatch, path: candidate.path,
                            message: "same SHA-256 as \(reference.path) but different bytes; not treated as a duplicate"))
                    }
                } catch {
                    if case .cancelled = error { return outcome }
                    // Work out which of the two files failed.
                    if error.path == reference.path {
                        outcome.issues.append(ScanIssue(error, fallbackPath: reference.path))
                        referenceFailed = true
                        break
                    }
                    excluded.insert(candidate.path)
                    outcome.issues.append(ScanIssue(error, fallbackPath: candidate.path))
                }
            }
            if !referenceFailed {
                outcome.confirmed = confirmed
                return outcome
            }
            // The reference became unreadable: start over with the next file as reference.
        }
        return outcome
    }
}

struct HashKey: Hashable, Sendable {
    let size: Int64
    let sha256: String
}
