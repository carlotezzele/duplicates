import AppKit
import DoppioCore
import SwiftUI

struct SummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let clean = model.cleanResult {
            VStack(spacing: 20) {
                Image(systemName: clean.trashed.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(clean.trashed.isEmpty ? Color.orange : Color.green)
                VStack(spacing: 6) {
                    Text("Moved \(Format.count(clean.trashed.count, "file")) to the Trash")
                        .font(.largeTitle.weight(.semibold))
                    Text("\(Format.bytes(clean.reclaimableBytes)) will be freed when you empty the Trash.")
                        .font(.title3).foregroundStyle(.secondary)
                    if clean.cancelled {
                        Text("Stopped at your request: \(Format.count(clean.notReached, "file")) not reached, left where they were.")
                    }
                    if let reason = clean.stopReason { Text("Stopped early: \(reason)").foregroundStyle(.red) }
                }
                if let restore = model.restoreResult {
                    Text("Put back \(Format.count(restore.restored.count, "file")); \(restore.skipped.count.formatted()) could not be put back (see the restore summary).")
                        .padding(10)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if !clean.notMoved.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not moved: \(Format.count(clean.notMoved.count, "file")), left exactly where they were")
                            .font(.headline)
                        List(clean.notMoved, id: \.file.path) { outcome in
                            HStack {
                                Text(outcome.reason ?? outcome.file.path)
                                    .font(.callout).textSelection(.enabled)
                                Spacer()
                                RevealButton(path: outcome.file.path)
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                    .frame(maxWidth: 720)
                }
                HStack(spacing: 12) {
                    Button("Open Trash") {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                    }
                    Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clean.log.jsonl, clean.log.summary]) }
                    Button("Open Summary") { NSWorkspace.shared.open(clean.log.summary) }
                    Button("Put Everything Back…") { model.confirmingRestore = true }
                        .disabled(clean.trashed.isEmpty || model.restoreResult != nil || model.isRestoring)
                    Button("New Scan") { model.newScan() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isRestoring)
                }
                if model.isRestoring {
                    ProgressView(value: Double(model.restoreDone), total: Double(max(1, model.restoreTotal))) {
                        Text("Putting files back…")
                    }
                    .frame(width: 360)
                }
                Text("Log: \(clean.log.jsonl.path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog("Put \(Format.count(clean.trashed.count, "file")) back where they were?",
                                isPresented: $model.confirmingRestore) {
                Button("Put Back") { model.restoreAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Files are only put back if they're still in the Trash, unchanged, and nothing else is at their original location. Nothing is ever overwritten.")
            }
        }
    }
}
