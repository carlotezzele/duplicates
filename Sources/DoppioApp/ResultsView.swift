import AppKit
import DoppioCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.tab {
                case .suggested: SuggestedView()
                case .review: ReviewView()
                case .problems: ProblemsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .quickLookPreview($model.previewURL, in: previewItems)
        .sheet(isPresented: $model.confirmingTrash) { ConfirmTrashSheet() }
        .onChange(of: model.exportRequested) { _, requested in
            if requested {
                model.exportRequested = false
                exportReport()
            }
        }
    }

    /// Lets the arrow keys in the Quick Look panel step through the current group.
    private var previewItems: [URL] {
        if model.tab == .review, let group = model.currentReviewGroup {
            return group.files.map { URL(fileURLWithPath: $0.path) }
        }
        return model.previewURL.map { [$0] } ?? []
    }

    private var header: some View {
        @Bindable var model = model
        let result = model.result!
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.groups.isEmpty ? "No exact duplicates found" : "\(Format.count(result.groups.count, "duplicate group")) · \(Format.count(result.redundantFileCount, "redundant copy", plural: "redundant copies"))")
                    .font(.headline)
                Text("\(result.reclaimableIsExact ? "" : "Up to ")\(Format.bytes(result.reclaimableBytes)) can be freed · \(Format.count(result.filesConsidered, "file")) checked in \(result.roots.paths.map(Format.name).joined(separator: ", "))")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("", selection: $model.tab) {
                Text("Suggested (\(model.suggestedGroups.count.formatted()))").tag(ResultsTab.suggested)
                Text("Needs Your Choice (\(model.reviewGroups.count.formatted()))").tag(ResultsTab.review)
                if !result.issues.isEmpty || !result.skipped.lines.isEmpty {
                    Text("Skipped & Problems").tag(ResultsTab.problems)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        let totals = model.totals
        return HStack(spacing: 12) {
            Button("New Scan") { model.newScan() }
            Button("Export Audit Report…") { exportReport() }
            Spacer()
            if totals.files > 0 {
                Text("\(Format.count(totals.files, "file")) selected · \(Format.bytes(totals.bytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Move \(Format.count(totals.files, "File")) to Trash…") { model.confirmingTrash = true }
                .controlSize(.large)
                .disabled(totals.files == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func exportReport() {
        guard let result = model.result else { return }
        let panel = NSSavePanel()
        panel.title = "Export Audit Report"
        panel.message = "Doppio saves a JSON and a CSV file side by side. It can't be saved inside a scanned folder."
        panel.allowedContentTypes = [.json]
        let stamp = result.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        panel.nameFieldStringValue = "doppio-audit-\(stamp).json"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { model.exportReport(to: url) }
    }
}

struct ConfirmTrashSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.totals
        VStack(alignment: .leading, spacing: 16) {
            Label("Move \(Format.count(t.files, "file")) to the Trash?", systemImage: "trash")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                if t.suggestedFiles > 0 {
                    Text("• \(Format.count(t.suggestedFiles, "file")) from \(Format.count(t.suggestedGroups, "suggested group")) (\(Format.bytes(t.suggestedBytes)))")
                }
                if t.chosenFiles > 0 {
                    Text("• \(Format.count(t.chosenFiles, "file")) from \(Format.count(t.chosenGroups, "group")) you reviewed (\(Format.bytes(t.chosenBytes)))")
                }
                Text("About \(Format.bytes(t.reclaimable)) is freed once you empty the Trash.")
                    .foregroundStyle(.secondary)
            }
            Text("Every group keeps one file. Right before each file is moved, Doppio checks again that the copy it keeps is still there and byte-identical; anything that fails a check stays where it is. Every move is logged and can be put back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.confirmingTrash = false }
                    .keyboardShortcut(.cancelAction)
                // Deliberately no keyboard shortcut: moving files takes a click.
                Button("Move to Trash", role: .destructive) { model.startClean() }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct ProblemsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let result = model.result!
        if result.issues.isEmpty && result.skipped.lines.isEmpty {
            ContentUnavailableView("Nothing skipped", systemImage: "checkmark.circle",
                                   description: Text("Every file in the scanned folders could be read and checked."))
        } else {
            problemList(result)
        }
    }

    private func problemList(_ result: ScanResult) -> some View {
        List {
            if !result.issues.isEmpty {
                Section("Couldn't be checked (\(result.issues.count.formatted())) — never treated as unique or duplicate") {
                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text(issue.message).textSelection(.enabled)
                                Text(issue.kind.rawValue.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            RevealButton(path: issue.path)
                        }
                    }
                }
            }
            if !result.skipped.lines.isEmpty {
                Section("Skipped on purpose") {
                    ForEach(result.skipped.lines, id: \.0) { label, count in
                        LabeledContent(label.capitalizedFirst, value: count.formatted())
                    }
                }
            }
        }
    }
}
