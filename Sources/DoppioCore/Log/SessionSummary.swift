import Foundation

/// Human-readable companions to the JSONL session logs.
public enum SessionSummary {
    public static func clean(_ r: CleanResult) -> String {
        var out: [String] = []
        out.append("Doppio \(Doppio.version) — clean session")
        out.append("Started:  \(display(r.startedAt))")
        out.append("Finished: \(display(r.finishedAt))")
        out.append("Folders:  \(r.roots.paths.joined(separator: ", "))")
        out.append("")
        out.append("Moved to the Trash: \(r.trashed.count) files, \(formatBytes(r.trashedBytes)) (frees about \(formatBytes(r.reclaimableBytes)) once the Trash is emptied)")
        out.append("Not moved:          \(r.notMoved.count) files (all left exactly where they were)")
        if r.notReached > 0 { out.append("Not reached:        \(r.notReached) files (left where they were)") }
        if r.cancelled { out.append("The session was cancelled before it finished.") }
        if let reason = r.stopReason { out.append("The session stopped early: \(reason)") }
        out.append("")
        out.append("To put these files back:")
        out.append("  doppio restore \(shellQuoted(r.log.jsonl.path))")
        if !r.trashed.isEmpty {
            out.append("")
            out.append("MOVED TO THE TRASH")
            for o in r.trashed {
                out.append("  \(o.file.path)")
                if case let .trashed(trashPath) = o.status { out.append("    now in the Trash: \(trashPath ?? "unknown location")") }
                out.append("    identical copy kept: \(o.kept)")
            }
        }
        if !r.notMoved.isEmpty {
            out.append("")
            out.append("NOT MOVED")
            for o in r.notMoved {
                out.append("  \(o.file.path)")
                out.append("    \(o.reason ?? "")")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public static func restore(_ r: RestoreResult) -> String {
        var out: [String] = []
        out.append("Doppio \(Doppio.version) — restore session")
        out.append("Date:      \(display(Date()))")
        out.append("From log:  \(r.plan.log.path)")
        out.append("")
        out.append("Put back:     \(r.restored.count) files")
        out.append("Not restored: \(r.skipped.count) files")
        if r.cancelled { out.append("The session was cancelled before it finished.") }
        if let reason = r.stopReason { out.append("The session stopped early: \(reason)") }
        if !r.restored.isEmpty {
            out.append("")
            out.append("PUT BACK")
            for o in r.restored { out.append("  \(o.item.original)") }
        }
        if !r.skipped.isEmpty {
            out.append("")
            out.append("NOT RESTORED")
            for o in r.skipped {
                out.append("  \(o.item.original)")
                if case let .skipped(reason) = o.status { out.append("    \(reason) (in the Trash: \(o.item.trashPath))") }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func display(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

/// Single-quotes a path for copy-pasting into a shell.
public func shellQuoted(_ s: String) -> String {
    let safe = s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@%:,".contains($0) }
    return safe ? s : "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
