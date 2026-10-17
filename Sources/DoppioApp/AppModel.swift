import AppKit
import DoppioCore
import Foundation
import Observation

enum Stage: Equatable {
    case setup, scanning, results, cleaning, summary
}

enum ResultsTab: Hashable {
    case suggested, review, problems
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Status of an ambiguous group in the review.
enum ReviewStatus: Equatable {
    case undecided
    case keepAll
    case keep(index: Int)
}

/// All app state. Every change to files goes through DoppioCore (`Cleaner`, `Restorer`),
/// which enforces the safety checks; this class only collects the user's decisions.
@MainActor @Observable
final class AppModel {
    // Setup
    var folders: [URL] = []
    var includeAllTypes = false
    var jobs = 1
    var randomNamesAreCopies = false

    var stage: Stage = .setup
    var alert: AlertMessage?
    private(set) var scanProgress: ScanProgress?
    private(set) var cleanProgress: CleanProgress?
    private(set) var restoreDone = 0
    private(set) var restoreTotal = 0

    // Results
    private(set) var result: ScanResult?
    private(set) var suggestedGroups: [DuplicateGroup] = []
    private(set) var reviewGroups: [DuplicateGroup] = []
    private(set) var selection = CleanSelection()
    private(set) var keptAll: Set<String> = [] // review groups where the user chose "keep all"
    var tab: ResultsTab = .suggested
    var reviewIndex: Int?
    /// The file Space / Reveal act on (the card or row last clicked).
    var focusedPath: String?
    var previewURL: URL?
    var confirmingTrash = false
    var exportRequested = false

    // After cleaning
    private(set) var cleanResult: CleanResult?
    private(set) var restoreResult: RestoreResult?
    private(set) var isRestoring = false
    private(set) var stopRequested = false
    var confirmingRestore = false

    private var task: Task<Void, Never>?
    private var onTaskFinished: (() -> Void)?

    /// Where session logs go. Tests point this (and `makeCleaner`) at temporary folders;
    /// the app always uses the defaults: ~/Library/Logs/Doppio and the system Trash.
    var logDirectory = SessionLog.defaultDirectory
    var makeCleaner: (ScanRoots, URL) -> Cleaner = { Cleaner(roots: $0, logDirectory: $1) }

    var isBusy: Bool { stage == .scanning || stage == .cleaning || isRestoring }
    /// True while files are being moved (quitting must wait for the current file).
    var isChangingFiles: Bool { stage == .cleaning || isRestoring }

    // MARK: - Setup

    func addFolders(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                alert = AlertMessage(title: "“\(url.lastPathComponent)” is not a folder",
                                     message: "Add folders or whole drives; Doppio scans everything inside them.")
                continue
            }
            if Exclusions.isInsidePackage(path: path) {
                alert = AlertMessage(title: "“\(url.lastPathComponent)” can't be scanned",
                                     message: "It is (or is inside) a package such as a Photos library. Doppio never looks inside packages, so it can never touch your Photos library.")
                continue
            }
            if !folders.contains(where: { $0.path == path }) {
                folders.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    // MARK: - Scan

    func startScan() {
        guard !folders.isEmpty, !isBusy else { return }
        let options = ScanOptions(roots: folders, includeAllTypes: includeAllTypes, jobs: jobs,
                                  suggestionRules: SuggestionRules(randomNamesAreCopies: randomNamesAreCopies))
        stage = .scanning
        scanProgress = nil
        task = Task {
            do {
                let result = try await DuplicateFinder(options: options).run { progress in
                    Task { @MainActor in
                        if self.stage == .scanning { self.scanProgress = progress }
                    }
                }
                show(result)
            } catch is CancellationError {
                stage = .setup
            } catch {
                alert = AlertMessage(title: "The scan couldn't run", message: String(describing: error))
                stage = .setup
            }
            taskFinished()
        }
    }

    func cancelScan() {
        task?.cancel()
    }

    func show(_ result: ScanResult) {
        self.result = result
        suggestedGroups = result.autoResolvableGroups
        reviewGroups = result.ambiguousGroups
        selection = CleanSelection()
        selection.acceptSuggestions(in: suggestedGroups)
        keptAll = []
        reviewIndex = reviewGroups.isEmpty ? nil : 0
        focusedPath = nil
        tab = suggestedGroups.isEmpty && !reviewGroups.isEmpty ? .review : .suggested
        cleanResult = nil
        restoreResult = nil
        stage = .results
    }

    func newScan() {
        guard !isBusy else { return }
        result = nil
        suggestedGroups = []
        reviewGroups = []
        selection = CleanSelection()
        cleanResult = nil
        restoreResult = nil
        previewURL = nil
        stage = .setup
    }

    // MARK: - Suggested groups (pre-checked)

    func isSelected(_ group: DuplicateGroup) -> Bool { selection.plan(for: group) != nil }

    func setSelected(_ group: DuplicateGroup, _ on: Bool) {
        if on { selection.acceptSuggestion(for: group) } else { selection.skip(group) }
    }

    func selectAllSuggestions(_ on: Bool) {
        if on {
            selection.acceptSuggestions(in: suggestedGroups)
        } else {
            for group in suggestedGroups { selection.skip(group) }
        }
    }

    var selectedSuggestionCount: Int { suggestedGroups.filter { selection.plan(for: $0) != nil }.count }

    // MARK: - Review (nothing pre-selected)

    var currentReviewGroup: DuplicateGroup? {
        guard let index = reviewIndex, reviewGroups.indices.contains(index) else { return nil }
        return reviewGroups[index]
    }

    func status(of group: DuplicateGroup) -> ReviewStatus {
        if let kept = selection.plan(for: group)?.keep.path, let index = group.files.firstIndex(where: { $0.path == kept }) {
            return .keep(index: index)
        }
        return keptAll.contains(group.id) ? .keepAll : .undecided
    }

    /// Keep file `index` (0-based) of the current group, then go to the next group.
    func keep(fileAt index: Int) {
        guard let group = currentReviewGroup, group.files.indices.contains(index) else { return }
        do {
            try selection.keep(group.files[index].path, in: group)
            keptAll.remove(group.id)
            next()
        } catch {
            selection.skip(group)
            alert = AlertMessage(title: "Nothing to move in this group", message: String(describing: error).capitalizedFirst + ".")
        }
    }

    func keepAll() {
        guard let group = currentReviewGroup else { return }
        selection.skip(group)
        keptAll.insert(group.id)
        next()
    }

    func next() {
        guard let index = reviewIndex, index + 1 < reviewGroups.count else { return }
        reviewIndex = index + 1
        focusedPath = nil
    }

    func previous() {
        guard let index = reviewIndex, index > 0 else { return }
        reviewIndex = index - 1
        focusedPath = nil
    }

    var decidedReviewCount: Int { reviewGroups.filter { status(of: $0) != .undecided }.count }

    var canUseReviewKeys: Bool { stage == .results && tab == .review && currentReviewGroup != nil && !confirmingTrash }

    // MARK: - Files

    func toggleQuickLook() {
        if previewURL != nil {
            previewURL = nil
        } else if let path = focusedPath ?? currentReviewGroupFocusFallback {
            previewURL = URL(fileURLWithPath: path)
        }
    }

    private var currentReviewGroupFocusFallback: String? {
        tab == .review ? currentReviewGroup?.files.first?.path : nil
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Totals

    var plans: [TrashPlan] { result.map { selection.plans(in: $0.groups) } ?? [] }

    struct Totals {
        var files = 0, bytes: Int64 = 0, reclaimable: Int64 = 0
        var suggestedFiles = 0, suggestedGroups = 0, suggestedBytes: Int64 = 0
        var chosenFiles = 0, chosenGroups = 0, chosenBytes: Int64 = 0
    }

    var totals: Totals {
        var t = Totals()
        for plan in plans {
            t.files += plan.trash.count
            t.bytes += plan.bytes
            t.reclaimable += plan.reclaimableBytes
            if plan.group.suggestion.isAutoResolvable {
                t.suggestedFiles += plan.trash.count
                t.suggestedGroups += 1
                t.suggestedBytes += plan.bytes
            } else {
                t.chosenFiles += plan.trash.count
                t.chosenGroups += 1
                t.chosenBytes += plan.bytes
            }
        }
        return t
    }

    // MARK: - Clean

    func startClean() {
        confirmingTrash = false
        guard let result, !isBusy else { return }
        let plans = self.plans
        guard !plans.isEmpty else { return }
        stage = .cleaning
        stopRequested = false
        cleanProgress = nil
        previewURL = nil
        task = Task {
            do {
                let clean = try await makeCleaner(result.roots, logDirectory).run(plans) { progress in
                    Task { @MainActor in
                        if self.stage == .cleaning { self.cleanProgress = progress }
                    }
                }
                cleanResult = clean
                stage = .summary
            } catch {
                alert = AlertMessage(title: "Nothing was moved", message: String(describing: error))
                stage = .results
            }
            taskFinished()
        }
    }

    func stopClean() {
        stopRequested = true
        task?.cancel()
    }

    // MARK: - Restore

    func restoreAll() {
        confirmingRestore = false
        guard let clean = cleanResult, !isBusy else { return }
        isRestoring = true
        restoreDone = 0
        restoreTotal = clean.trashed.count
        task = Task {
            do {
                let plan = try Restorer.load(clean.log.jsonl)
                restoreResult = try await Restorer(logDirectory: logDirectory).run(plan) { done, total in
                    Task { @MainActor in
                        self.restoreDone = done
                        self.restoreTotal = total
                    }
                }
            } catch {
                alert = AlertMessage(title: "Nothing was put back", message: String(describing: error))
            }
            isRestoring = false
            taskFinished()
        }
    }

    // MARK: - Report

    func exportReport(to url: URL) {
        guard let result else { return }
        let paths = AuditReport.paths(for: url, startedAt: result.startedAt)
        do {
            try AuditReport.validate(paths, roots: result.roots)
            try AuditReport.write(result, to: paths)
            NSWorkspace.shared.activateFileViewerSelecting([paths.json, paths.csv])
        } catch {
            alert = AlertMessage(title: "The report wasn't saved", message: String(describing: error))
        }
    }

    // MARK: - Quitting

    /// Asks a running clean or restore to stop after the current file, then calls `done`.
    func stopForQuit(_ done: @escaping () -> Void) {
        onTaskFinished = done
        stopRequested = true
        task?.cancel()
    }

    private func taskFinished() {
        task = nil
        onTaskFinished?()
        onTaskFinished = nil
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
