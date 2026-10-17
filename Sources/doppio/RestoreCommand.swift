import ArgumentParser
import DoppioCore
import Foundation

struct RestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Put the files a clean session moved to the Trash back where they were. Never overwrites anything.",
        discussion: """
        A file is put back only if it is still in the Trash, is still the very file Doppio \
        moved there (same size and SHA-256), its original folder still exists, and nothing \
        else is at its original path. Anything else is skipped and reported. Without a log \
        file, lists recent clean sessions.
        """
    )

    @Argument(help: "The session log printed by doppio clean (doppio-clean-….jsonl).", completion: .file(extensions: ["jsonl"]))
    var log: String?

    @Flag(name: .long, help: "Show what would be restored without changing anything.")
    var dryRun = false

    func run() async throws {
        guard let log else {
            listSessions()
            return
        }
        let plan = try Restorer.load(URL(fileURLWithPath: (log as NSString).expandingTildeInPath))
        print("Clean session of \(localTime(plan.startedAt)) in \(plan.roots.joined(separator: ", "))")
        print("\(plural(plan.items.count, "file")) moved to the Trash in that session.")
        for problem in plan.problems { printError("  Note: \(problem)") }

        let checks = plan.items.map { (item: $0, reason: Restorer.preflight($0)) }
        let ready = checks.filter { $0.reason == nil }.map(\.item)
        let alreadyBack = checks.filter { $0.reason == Restorer.alreadyBackReason }
        let blocked = checks.filter { $0.reason != nil && $0.reason != Restorer.alreadyBackReason }
        if !alreadyBack.isEmpty { print("Already back in place: \(plural(alreadyBack.count, "file")).") }
        if !blocked.isEmpty {
            print("\nCan't be put back: \(plural(blocked.count, "file")), left as they are:")
            for (reason, items) in Dictionary(grouping: blocked, by: { $0.reason! }).sorted(by: { $0.value.count > $1.value.count }) {
                print("  \(items.count) × \(reason)")
                for entry in items.prefix(3) { print("      \(entry.item.original)") }
                if items.count > 3 { print("      …") }
            }
        }
        guard !ready.isEmpty else {
            print("\nNothing to restore. Nothing was changed.")
            return
        }
        print("\nReady to put back: \(plural(ready.count, "file")), \(formatBytes(ready.reduce(0) { $0 + $1.size }))")
        if dryRun {
            for item in ready.prefix(20) { print("  \(item.original)") }
            if ready.count > 20 { print("  … and \(ready.count - 20) more") }
            print("Dry run: nothing was changed.")
            return
        }
        guard Prompt.isInteractive else {
            printError("doppio restore asks for confirmation, so it must be run in a terminal (or use --dry-run). Nothing was changed.")
            throw ExitCode.failure
        }
        guard Prompt.confirm("Move \(plural(ready.count, "file")) from the Trash back to their original locations?") else {
            print("Nothing was changed.")
            return
        }

        let line = ProgressLine()
        let result = try await runCancellableOnSIGINT(notice: "\nStopping after the current file…\n") {
            try await Restorer().run(plan, only: ready) { done, total in line.show("Putting back: \(done)/\(total) files") }
        }
        line.clear()
        print("Put back: \(plural(result.restored.count, "file"))")
        if result.cancelled { print("Stopped at your request; the rest are still in the Trash.") }
        if let reason = result.stopReason { printError("Stopped early: \(reason)") }
        if !result.skipped.isEmpty {
            print("Not put back: \(plural(result.skipped.count, "file")):")
            for outcome in result.skipped.prefix(15) {
                if case let .skipped(reason) = outcome.status { print("  \(outcome.item.original): \(reason)") }
            }
            if result.skipped.count > 15 { print("  … and \(result.skipped.count - 15) more (see the summary)") }
        }
        print("\nLog:     \(result.log.jsonl.path)")
        print("Summary: \(result.log.summary.path)")
    }

    private func listSessions() {
        let folder = SessionLog.defaultDirectory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("doppio-clean-") && $0.hasSuffix(".jsonl") }
            .sorted(by: >)
        guard !names.isEmpty else {
            print("No clean sessions found in \(folder.path).")
            return
        }
        print("Recent clean sessions (newest first). Restore one with: doppio restore <log>\n")
        for name in names.prefix(10) {
            let url = folder.appendingPathComponent(name)
            let entries = (try? SessionLog.read(url))?.entries ?? []
            let trashed = entries.filter { $0.event == .trashed }.count
            let roots = entries.first?.roots?.joined(separator: ", ") ?? "?"
            print("  \(shellQuoted(url.path))")
            print("    \(entries.first.map { localTime($0.time) } ?? "?") · \(plural(trashed, "file")) moved to the Trash · \(roots)")
        }
    }
}
