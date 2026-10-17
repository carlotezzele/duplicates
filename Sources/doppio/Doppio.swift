import ArgumentParser
import DoppioCore
import Foundation

@main
struct DoppioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doppio",
        abstract: "Find exact duplicate photos and videos, safely.",
        version: Doppio.version,
        subcommands: [AuditCommand.self, CleanCommand.self, RestoreCommand.self]
    )
}

struct ScanFlags: ParsableArguments {
    @Argument(help: "Folders to scan (external drives included).", completion: .directory)
    var folders: [String]

    @Flag(name: .long, help: "Consider every file type, not just photos and videos.")
    var allTypes = false

    @Option(name: .long, help: "Files read in parallel. Keep 1 for spinning hard disks; 2–4 for SSDs.")
    var jobs = 1

    @Flag(name: .long, help: "Suggestions: treat random-looking names (e.g. NBQE3618.jpg) as copies of a real-named file.")
    var randomNamesAreCopies = false

    func validate() throws {
        guard !folders.isEmpty else { throw ValidationError("Give at least one folder.") }
        guard (1...16).contains(jobs) else { throw ValidationError("--jobs must be between 1 and 16.") }
    }

    var options: ScanOptions {
        ScanOptions(roots: folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                    includeAllTypes: allTypes, jobs: jobs,
                    suggestionRules: SuggestionRules(randomNamesAreCopies: randomNamesAreCopies))
    }
}

struct AuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Scan and write a report. Strictly read-only: nothing is moved, renamed or deleted.",
        discussion: """
        The report is written as JSON and CSV to ~/Library/Logs/Doppio/Reports unless --report \
        is given: a path ending in .json or .csv names the files, anything else is a folder \
        (created if needed). It may not be inside a scanned folder.
        """
    )

    @OptionGroup var scan: ScanFlags

    @Option(name: .long, help: "Where to write the report.", completion: .file())
    var report: String?

    func run() async throws {
        let destination = report.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let console = ProgressLine()
        let (result, paths) = try await runCancellableOnSIGINT {
            try await Audit.run(scan.options, reportDestination: destination) { console.update($0) }
        }
        console.clear()
        print("Doppio audit (read-only, nothing was modified)\n")
        print(AuditReport.consoleSummary(result))
        printIssues(result.issues)
        print("\nReport:\n  \(paths.json.path)\n  \(paths.csv.path)")
    }
}

func printIssues(_ issues: [ScanIssue], limit: Int = 15) {
    guard !issues.isEmpty else { return }
    var err = StandardError()
    print("\nFiles Doppio could not check:", to: &err)
    for issue in issues.prefix(limit) { print("  \(issue.message)", to: &err) }
    if issues.count > limit { print("  … and \(issues.count - limit) more (see the report)", to: &err) }
}
