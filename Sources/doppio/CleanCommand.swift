import ArgumentParser
import DoppioCore
import Foundation

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Move duplicate copies to the Trash, only after you confirm. Every move is logged and can be undone.",
        discussion: """
        Doppio scans the folders, then:
          1. shows the automatic suggestions and asks whether to include them;
          2. offers to review the groups that need your choice, one at a time;
          3. shows the total and asks for a final confirmation.
        Nothing is moved before that final "y". Right before each file is moved, Doppio checks \
        again that the copy it keeps is still there and byte-identical. Files only ever go to \
        the Trash; Doppio never deletes anything. Undo with `doppio restore <log>`.
        """
    )

    @OptionGroup var scan: ScanFlags

    func run() async throws {
        guard Prompt.isInteractive else {
            printError("doppio clean asks for confirmation, so it must be run in a terminal. Nothing was changed.")
            throw ExitCode.failure
        }
        let console = ProgressLine()
        let result = try await runCancellableOnSIGINT {
            try await DuplicateFinder(options: scan.options).run { console.update($0) }
        }
        console.clear()
        print(AuditReport.consoleSummary(result))
        printIssues(result.issues)
        guard !result.groups.isEmpty else {
            print("\nNothing to clean. Nothing was changed.")
            return
        }

        var selection = CleanSelection()
        guard offerSuggestions(result, &selection) else { return }
        let ambiguous = result.ambiguousGroups
        if !ambiguous.isEmpty {
            print()
            if Prompt.confirm("Review the \(plural(ambiguous.count, "group")) that need\(ambiguous.count == 1 ? "s" : "") your choice now?") {
                await Review(groups: ambiguous).run(&selection)
            }
        }

        let plans = selection.plans(in: result.groups)
        guard !plans.isEmpty else {
            print("\nNothing selected. Nothing was changed.")
            return
        }
        guard confirmFinal(plans) else {
            print("Nothing was changed.")
            return
        }

        let progress = ProgressLine()
        let clean = try await runCancellableOnSIGINT(notice: "\nStopping after the current file…\n") {
            try await Cleaner(roots: result.roots).run(plans) { progress.update($0) }
        }
        progress.clear()
        report(clean)
    }

    /// Returns false if the user ended input (Ctrl-D): stop without doing anything.
    private func offerSuggestions(_ result: ScanResult, _ selection: inout CleanSelection) -> Bool {
        let plans = result.autoResolvableGroups.compactMap(TrashPlan.suggested)
        guard !plans.isEmpty else { return true }
        print("\nAutomatic suggestions: \(plural(plans.count, "group")), \(plural(Self.count(plans), "file")) to the Trash, \(formatBytes(Self.bytes(plans)))")
        print("In each group Doppio keeps the file whose name has no copy marker. For example:")
        for plan in plans.prefix(2) { print(Self.describe(plan)) }
        while true {
            guard let answer = Prompt.ask("Include the automatic suggestions? [y = yes, n = no (default), l = list them all] ") else {
                print("Nothing was changed.")
                return false
            }
            switch answer.lowercased() {
            case "y", "yes":
                selection.acceptSuggestions(in: result.groups)
                return true
            case "l", "list":
                page(plans.map(Self.describe).joined(separator: "\n"))
            default:
                print("Automatic suggestions not included.")
                return true
            }
        }
    }

    private func confirmFinal(_ plans: [TrashPlan]) -> Bool {
        let auto = plans.filter { $0.group.suggestion.isAutoResolvable }
        let chosen = plans.filter { !$0.group.suggestion.isAutoResolvable }
        print("\nReady to move to the Trash:")
        if !auto.isEmpty {
            print("  automatic suggestions: \(plural(Self.count(auto), "file")) from \(plural(auto.count, "group")), \(formatBytes(Self.bytes(auto)))")
        }
        if !chosen.isEmpty {
            print("  your choices:          \(plural(Self.count(chosen), "file")) from \(plural(chosen.count, "group")), \(formatBytes(Self.bytes(chosen)))")
        }
        let reclaimable = plans.reduce(0) { $0 + $1.reclaimableBytes }
        print("  total:                 \(plural(Self.count(plans), "file")), \(formatBytes(Self.bytes(plans))) (frees about \(formatBytes(reclaimable)) once you empty the Trash)")
        print("Right before each file is moved, Doppio re-checks that the copy it keeps is still there and byte-identical.")
        return Prompt.confirm("Move \(plural(Self.count(plans), "file")) to the Trash?")
    }

    private func report(_ clean: CleanResult) {
        print("Moved to the Trash: \(plural(clean.trashed.count, "file")), \(formatBytes(clean.trashedBytes)) (frees about \(formatBytes(clean.reclaimableBytes)) once you empty the Trash)")
        if clean.cancelled { print("Stopped at your request; \(plural(clean.notReached, "file")) not reached, left untouched.") }
        if let reason = clean.stopReason { printError("Stopped early: \(reason)") }
        let notMoved = clean.notMoved
        if !notMoved.isEmpty {
            print("Not moved: \(plural(notMoved.count, "file")), left exactly where they were:")
            for outcome in notMoved.prefix(15) { print("  \(outcome.reason ?? outcome.file.path)") }
            if notMoved.count > 15 { print("  … and \(notMoved.count - 15) more (see the summary)") }
        }
        print("\nLog:     \(clean.log.jsonl.path)")
        print("Summary: \(clean.log.summary.path)")
        if !clean.trashed.isEmpty { print("To undo: doppio restore \(shellQuoted(clean.log.jsonl.path))") }
    }

    static func count(_ plans: [TrashPlan]) -> Int { plans.reduce(0) { $0 + $1.trash.count } }
    static func bytes(_ plans: [TrashPlan]) -> Int64 { plans.reduce(0) { $0 + $1.bytes } }

    static func describe(_ plan: TrashPlan) -> String {
        (["  keep   \(plan.keep.path)"] + plan.trash.map { "  trash  \($0.path)" }
            + plan.untouched.map { "  stays  \($0.path)  (hard link)" }).joined(separator: "\n")
    }
}

/// One-at-a-time review of the groups Doppio could not decide. Nothing is pre-selected:
/// a group only gets a plan when the user types the number of the file to keep.
struct Review {
    let groups: [DuplicateGroup]

    static let help = """
      1–9…   keep that file, move the other copies to the Trash
      s      keep all files in this group
      Enter  next group (leaves the current choice as it is)
      b      back to the previous group
      l      show this group again
      o N    preview file N with Quick Look
      r N    show file N in Finder
      q      stop reviewing (remaining groups keep all their files)
    """

    func run(_ selection: inout CleanSelection) async {
        print("\nFor each group, type the number of the file to keep. ? shows all commands.")
        var index = 0
        var shown: Int?
        while index < groups.count {
            let group = groups[index]
            if shown != index {
                await show(group, number: index + 1, chosen: selection.plan(for: group))
                shown = index
            }
            guard let answer = Prompt.ask("> ") else { return }
            let files = group.files
            let parts = answer.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let number = parts.count == 2 ? Int(parts[1]) : nil
            switch (parts.first?.lowercased(), number) {
            case (nil, _):
                index += 1
            case let (word?, nil) where Int(word) != nil:
                let n = Int(word)!
                guard (1...files.count).contains(n) else { print("  Type a number from 1 to \(files.count)."); continue }
                do {
                    try selection.keep(files[n - 1].path, in: group)
                    let plan = selection.plan(for: group)!
                    print("  Keeping \(n); \(plural(plan.trash.count, "file")) will go to the Trash.")
                } catch {
                    selection.skip(group)
                    print("  \(error). Keeping all files in this group.")
                }
                index += 1
            case ("s", nil):
                selection.skip(group)
                print("  Keeping all files in this group.")
                index += 1
            case ("b", nil):
                if index > 0 { index -= 1 } else { print("  This is the first group.") }
            case ("l", nil):
                shown = nil
            case let ("o", n?) where (1...files.count).contains(n):
                launch("/usr/bin/qlmanage", ["-p", files[n - 1].path])
            case let ("r", n?) where (1...files.count).contains(n):
                launch("/usr/bin/open", ["-R", files[n - 1].path])
            case ("q", nil):
                print("  Stopped reviewing; the remaining groups keep all their files.")
                return
            case ("?", nil), ("h", nil), ("help", nil):
                print(Self.help)
            default:
                print("  Not understood. Type a number from 1 to \(files.count), or ? for help.")
            }
        }
        print("  That was the last group.")
    }

    private func show(_ group: DuplicateGroup, number: Int, chosen: TrashPlan?) async {
        print("\nGroup \(number) of \(groups.count): \(group.files.count) identical files, \(formatBytes(group.size)) each")
        for (i, file) in group.files.enumerated() {
            print("  \(i + 1)  \(file.path)")
            var details = ["created \(shortDate(file.record.created.date))", "modified \(shortDate(file.record.modified.date))"]
            if let taken = await CaptureDate.read(path: file.path) { details.append("taken \(shortDate(taken))") }
            print("     " + details.joined(separator: " · "))
            if !file.canBeTrashed { print("     hard link: never moved to the Trash") }
        }
        if let chosen, let n = group.files.firstIndex(where: { $0.path == chosen.keep.path }) {
            print("  Current choice: keep \(n + 1)")
        }
    }
}
