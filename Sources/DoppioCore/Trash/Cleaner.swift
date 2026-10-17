import Foundation

/// Moves one file to the Trash. Outside the tests the only implementation is `SystemTrash`;
/// there is deliberately no way to delete a file permanently.
protocol TrashMover: Sendable {
    /// Returns the file's new location in the Trash, if the system reports it.
    func moveToTrash(_ path: String) throws -> String?
}

/// `FileManager.trashItem`: the right Trash for each volume (`~/.Trash`, or
/// `.Trashes/<uid>` on external drives). If a volume has no Trash, it throws, and the
/// file is reported and left where it is.
struct SystemTrash: TrashMover {
    func moveToTrash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }
}

public struct CleanProgress: Sendable {
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesVerified: Int64 = 0
    public var bytesTotal: Int64 = 0

    public var fraction: Double? { bytesTotal > 0 ? min(1, Double(bytesVerified) / Double(bytesTotal)) : nil }
}

public struct CleanOutcome: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case trashed(trashPath: String?)
        /// A safety check failed; the file was not touched.
        case skipped(reason: String)
        /// Moving it to the Trash failed (e.g. the volume has no Trash); the file was not touched.
        case failed(reason: String)
    }

    public let file: DuplicateFile
    public let kept: String
    public let status: Status

    public var wasTrashed: Bool { if case .trashed = status { true } else { false } }
    public var reason: String? {
        switch status {
        case .trashed: nil
        case let .skipped(reason), let .failed(reason): reason
        }
    }
}

public struct CleanResult: Sendable {
    public let roots: ScanRoots
    public let outcomes: [CleanOutcome]
    /// Files planned but never reached (cancelled or stopped).
    public let notReached: Int
    public let cancelled: Bool
    /// Set when the session stopped early because the log could not be written.
    public let stopReason: String?
    public let log: SessionLog.Paths
    public let startedAt: Date
    public let finishedAt: Date

    public var trashed: [CleanOutcome] { outcomes.filter(\.wasTrashed) }
    public var notMoved: [CleanOutcome] { outcomes.filter { !$0.wasTrashed } }
    public var trashedBytes: Int64 { trashed.reduce(0) { $0 + $1.file.record.size } }
    /// Space freed once the Trash is emptied.
    public var reclaimableBytes: Int64 { trashed.reduce(0) { $0 + $1.file.reclaimableSize } }
}

public enum CleanError: Error, Sendable, CustomStringConvertible, Equatable {
    case conflictingPlans(path: String)
    case outsideScannedFolders(path: String)

    public var description: String {
        switch self {
        case let .conflictingPlans(p): "\(p) appears in more than one plan. Nothing was changed."
        case let .outsideScannedFolders(p): "\(p) is not inside a scanned folder. Nothing was changed."
        }
    }
}

/// Executes confirmed plans: for each file, the safety checks, then an fsync'ed "intent"
/// log line, then the move to the Trash, then a "trashed" line. Files are handled one at a
/// time; cancelling stops before the next file, never in the middle of one.
public struct Cleaner: Sendable {
    public let roots: ScanRoots
    public let logDirectory: URL
    let mover: any TrashMover

    public init(roots: ScanRoots, logDirectory: URL = SessionLog.defaultDirectory) {
        self.init(roots: roots, logDirectory: logDirectory, mover: SystemTrash())
    }

    init(roots: ScanRoots, logDirectory: URL, mover: any TrashMover) {
        self.roots = roots
        self.logDirectory = logDirectory
        self.mover = mover
    }

    /// Cancel the surrounding Task to stop after the current file; the result says so.
    public func run(_ plans: [TrashPlan],
                    progress: @escaping @Sendable (CleanProgress) -> Void = { _ in }) async throws -> CleanResult {
        try validate(plans)
        let log = try SessionLog(kind: "clean", directory: logDirectory)
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Blocking.run { try execute(plans, log: log, cancel: cancel, progress: progress) }
        } onCancel: {
            cancel.cancel()
        }
    }

    /// Structural checks over all plans together, before anything happens.
    func validate(_ plans: [TrashPlan]) throws(CleanError) {
        var seen = Set<String>()
        for plan in plans {
            for path in [plan.keep.path] + plan.trash.map(\.path) {
                guard seen.insert(path).inserted else { throw .conflictingPlans(path: path) }
            }
            for file in plan.trash where !roots.contains(file.path) {
                throw .outsideScannedFolders(path: file.path)
            }
        }
    }

    private func execute(_ plans: [TrashPlan], log: SessionLog, cancel: CancelFlag,
                         progress: @escaping @Sendable (CleanProgress) -> Void) throws -> CleanResult {
        let started = Date()
        var start = LogEntry(.sessionStart, at: started)
        start.tool = "doppio"
        start.version = Doppio.version
        start.command = "clean"
        start.roots = roots.paths
        try log.append(start)

        let total = plans.reduce(0) { $0 + $1.trash.count }
        let tracker = CleanProgressTracker(
            CleanProgress(filesTotal: total, bytesTotal: plans.reduce(0) { $0 + $1.bytes * 2 }), handler: progress)
        var outcomes: [CleanOutcome] = []
        var cancelled = false
        var stopReason: String?

        func record(_ event: LogEntry.Event, _ file: DuplicateFile, _ plan: TrashPlan,
                    sha: String? = nil, trash: String? = nil, reason: String? = nil) throws(LogError) {
            var entry = LogEntry(event)
            entry.group = plan.group.sha256
            entry.original = file.path
            entry.kept = plan.keep.path
            entry.size = file.record.size
            entry.sha256 = sha ?? plan.group.sha256
            entry.device = file.record.device
            entry.inode = file.record.inode
            entry.trash = trash
            entry.reason = reason
            try log.append(entry)
        }

        work: for plan in plans {
            for file in plan.trash {
                if cancel.isCancelled { cancelled = true; break work }
                do {
                    let sha: String
                    do {
                        sha = try SafetyGuard.check(file, keeping: plan.keep, in: plan.group, roots: roots,
                                                    cancel: cancel) { tracker.add(bytes: Int64($0)) }
                    } catch {
                        if case .cancelled = error { cancelled = true; break work }
                        try record(.skipped, file, plan, reason: error.description)
                        outcomes.append(CleanOutcome(file: file, kept: plan.keep.path, status: .skipped(reason: error.description)))
                        tracker.add(files: 1)
                        continue
                    }
                    try record(.intent, file, plan, sha: sha)
                    let trashPath: String?
                    do {
                        trashPath = try mover.moveToTrash(file.path)
                    } catch {
                        let reason = "could not move it to the Trash: \(error.localizedDescription)"
                        try record(.failed, file, plan, sha: sha, reason: reason)
                        outcomes.append(CleanOutcome(file: file, kept: plan.keep.path, status: .failed(reason: reason)))
                        tracker.add(files: 1)
                        continue
                    }
                    try record(.trashed, file, plan, sha: sha, trash: trashPath,
                               reason: Self.trashLocationWarning(file, trashPath))
                    outcomes.append(CleanOutcome(file: file, kept: plan.keep.path, status: .trashed(trashPath: trashPath)))
                    tracker.add(files: 1)
                } catch {
                    stopReason = String(describing: error)
                    break work
                }
            }
        }

        let finished = Date()
        let result = CleanResult(roots: roots, outcomes: outcomes, notReached: total - outcomes.count,
                                 cancelled: cancelled, stopReason: stopReason, log: log.paths,
                                 startedAt: started, finishedAt: finished)
        var end = LogEntry(.sessionEnd, at: finished)
        end.trashedCount = result.trashed.count
        end.skippedCount = outcomes.filter { if case .skipped = $0.status { true } else { false } }.count
        end.failedCount = outcomes.filter { if case .failed = $0.status { true } else { false } }.count
        end.bytes = result.trashedBytes
        end.cancelled = cancelled
        end.reason = stopReason
        try? log.append(end)
        try? log.writeSummary(SessionSummary.clean(result))
        tracker.finish()
        return result
    }

    /// The item in the Trash should be the very file that was checked (a move keeps the inode).
    private static func trashLocationWarning(_ file: DuplicateFile, _ trashPath: String?) -> String? {
        guard let trashPath else { return "the system did not report where in the Trash the file went" }
        guard let st = try? FileStat.lstat(trashPath) else { return "the file could not be found at its reported Trash location" }
        if st.device != file.record.device || st.inode != file.record.inode {
            return "the item at the reported Trash location is not the file that was checked"
        }
        return nil
    }
}

final class CleanProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var state: CleanProgress
    private let handler: @Sendable (CleanProgress) -> Void
    private var lastEmit: UInt64 = 0

    init(_ initial: CleanProgress, handler: @escaping @Sendable (CleanProgress) -> Void) {
        state = initial
        self.handler = handler
        handler(initial)
    }

    func add(files: Int = 0, bytes: Int64 = 0) {
        let snapshot: CleanProgress? = lock.withLock {
            state.filesDone += files
            state.bytesVerified += bytes
            let now = DispatchTime.now().uptimeNanoseconds
            guard now - lastEmit >= 100_000_000 else { return nil }
            lastEmit = now
            return state
        }
        if let snapshot { handler(snapshot) }
    }

    func finish() { handler(lock.withLock { state }) }
}
