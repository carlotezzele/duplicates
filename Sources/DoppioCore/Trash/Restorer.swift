import Darwin
import Foundation

public enum RestoreError: Error, Sendable, CustomStringConvertible, Equatable {
    case unreadableLog(String, String)
    case malformedLog(String, line: Int)
    case notACleanLog(String)

    public var description: String {
        switch self {
        case let .unreadableLog(path, reason): "Cannot read \(path): \(reason)"
        case let .malformedLog(path, line): "\(path) is damaged at line \(line); nothing was restored."
        case let .notACleanLog(path): "\(path) is not a Doppio clean log (doppio-clean-….jsonl)."
        }
    }
}

/// A file that a clean session moved to the Trash.
public struct RestoreItem: Sendable, Hashable {
    public let original: String
    public let trashPath: String
    public let kept: String?
    public let size: Int64
    public let sha256: String
    public let device: Int32
    public let inode: UInt64
}

/// What a clean log says can be put back.
public struct RestorePlan: Sendable {
    public let log: URL
    public let startedAt: String
    public let roots: [String]
    public let items: [RestoreItem]
    /// Entries that can't be restored automatically, with an explanation each.
    public let problems: [String]
}

public struct RestoreOutcome: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case restored
        case skipped(reason: String)
    }

    public let item: RestoreItem
    public let status: Status

    public var wasRestored: Bool { status == .restored }
}

public struct RestoreResult: Sendable {
    public let plan: RestorePlan
    public let outcomes: [RestoreOutcome]
    public let cancelled: Bool
    public let stopReason: String?
    public let log: SessionLog.Paths

    public var restored: [RestoreOutcome] { outcomes.filter(\.wasRestored) }
    public var skipped: [RestoreOutcome] { outcomes.filter { !$0.wasRestored } }
}

/// Puts trashed files back where they were. A file is only moved back if it is still the
/// very file Doppio trashed (same inode, size and SHA-256) and nothing exists at its
/// original path; the move itself uses `renamex_np(RENAME_EXCL)`, which can never
/// overwrite. If the original folder is gone, the file is skipped and reported.
public struct Restorer: Sendable {
    public let logDirectory: URL

    public init(logDirectory: URL = SessionLog.defaultDirectory) {
        self.logDirectory = logDirectory
    }

    public static func load(_ url: URL) throws -> RestorePlan {
        let (entries, incomplete) = try SessionLog.read(url)
        guard let start = entries.first, start.event == .sessionStart, start.tool == "doppio",
              start.command == "clean" else { throw RestoreError.notACleanLog(url.path) }

        var items: [RestoreItem] = []
        var problems: [String] = []
        var pending: [String: LogEntry] = [:] // intent without an outcome yet, by original path
        for entry in entries.dropFirst() {
            guard let original = entry.original else { continue }
            switch entry.event {
            case .intent:
                pending[original] = entry
            case .failed:
                pending[original] = nil
            case .trashed:
                pending[original] = nil
                guard let trash = entry.trash, let size = entry.size, let sha = entry.sha256,
                      let device = entry.device, let inode = entry.inode else {
                    problems.append("\(original): the log doesn't say where in the Trash it went; use Finder's Put Back")
                    continue
                }
                items.append(RestoreItem(original: original, trashPath: trash, kept: entry.kept, size: size,
                                         sha256: sha, device: device, inode: inode))
            default:
                continue
            }
        }
        for original in pending.keys.sorted() {
            problems.append("\(original): the session stopped while moving this file; check whether it is still in place or in the Trash")
        }
        if incomplete { problems.append("the last line of the log is incomplete (the session was interrupted)") }
        return RestorePlan(log: url, startedAt: start.time, roots: start.roots ?? [], items: items, problems: problems)
    }

    /// Quick checks that don't read file contents. nil = looks restorable.
    public static func preflight(_ item: RestoreItem) -> String? {
        if let st = try? FileStat.lstat(item.original) {
            if st.device == item.device && st.inode == item.inode { return alreadyBackReason }
            return "something else already exists at the original location"
        }
        guard let st = try? FileStat.lstat(item.trashPath) else {
            return "no longer in the Trash (restored already, put back, or the Trash was emptied)"
        }
        if st.isRegular, st.device != item.device, st.size == item.size {
            return "the Trash put it on a different volume; use Finder's Put Back for this file"
        }
        guard st.isRegular, st.device == item.device, st.inode == item.inode, st.size == item.size else {
            return "the item in the Trash is not the file Doppio moved there"
        }
        let folder = (item.original as NSString).deletingLastPathComponent
        guard let folderStat = try? FileStat.lstat(folder), folderStat.isDirectory else {
            return "its original folder no longer exists"
        }
        guard ScanRoots.realPath(folder) == folder else { return "its original folder path now goes through a symlink" }
        return nil
    }

    /// Cancel the surrounding Task to stop after the current file.
    public func run(_ plan: RestorePlan, only items: [RestoreItem]? = nil,
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> RestoreResult {
        let items = items ?? plan.items
        let log = try SessionLog(kind: "restore", directory: logDirectory)
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Blocking.run { try execute(plan, items, log: log, cancel: cancel, progress: progress) }
        } onCancel: {
            cancel.cancel()
        }
    }

    private func execute(_ plan: RestorePlan, _ items: [RestoreItem], log: SessionLog, cancel: CancelFlag,
                         progress: @Sendable (Int, Int) -> Void) throws -> RestoreResult {
        var start = LogEntry(.sessionStart)
        start.tool = "doppio"
        start.version = Doppio.version
        start.command = "restore"
        start.sourceLog = plan.log.path
        start.roots = plan.roots
        try log.append(start)

        var outcomes: [RestoreOutcome] = []
        var cancelled = false
        var stopReason: String?
        for (index, item) in items.enumerated() {
            if cancel.isCancelled { cancelled = true; break }
            progress(index, items.count)
            let status = restore(item, cancel: cancel)
            if case .skipped(reason: Self.cancelledReason) = status { cancelled = true; break }
            var entry = LogEntry(status == .restored ? .restored : .skipped)
            entry.original = item.original
            entry.trash = item.trashPath
            entry.kept = item.kept
            entry.size = item.size
            entry.sha256 = item.sha256
            entry.device = item.device
            entry.inode = item.inode
            if case let .skipped(reason) = status { entry.reason = reason }
            do { try log.append(entry) } catch {
                // The move already happened (or didn't); record it in memory and stop.
                outcomes.append(RestoreOutcome(item: item, status: status))
                stopReason = error.description
                break
            }
            outcomes.append(RestoreOutcome(item: item, status: status))
        }
        progress(outcomes.count, items.count)

        let result = RestoreResult(plan: plan, outcomes: outcomes, cancelled: cancelled, stopReason: stopReason,
                                   log: log.paths)
        var end = LogEntry(.sessionEnd)
        end.restoredCount = result.restored.count
        end.skippedCount = result.skipped.count
        end.cancelled = cancelled
        end.reason = stopReason
        try? log.append(end)
        try? log.writeSummary(SessionSummary.restore(result))
        return result
    }

    static let cancelledReason = "cancelled"
    public static let alreadyBackReason = "already back at its original location"

    private func restore(_ item: RestoreItem, cancel: CancelFlag) -> RestoreOutcome.Status {
        if let reason = Self.preflight(item) { return .skipped(reason: reason) }
        // Same content as when it was trashed?
        do {
            let st = try FileStat.lstat(item.trashPath)
            let sha = try ContentHasher.fullHash(FileRecord(path: item.trashPath, stat: st), cancel: cancel) { _ in }
            guard sha == item.sha256 else { return .skipped(reason: "its content changed while in the Trash") }
        } catch {
            if case .cancelled = error { return .skipped(reason: Self.cancelledReason) }
            return .skipped(reason: "could not be checked in the Trash (\(error.description))")
        }
        guard renamex_np(item.trashPath, item.original, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { return .skipped(reason: "something else already exists at the original location") }
            if code == EXDEV { return .skipped(reason: "the Trash and the original folder are on different volumes; use Finder's Put Back") }
            return .skipped(reason: "could not move it back: \(String(cString: strerror(code)))")
        }
        return .restored
    }
}
