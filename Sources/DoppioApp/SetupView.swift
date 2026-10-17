import AppKit
import DoppioCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.stage {
            case .setup: SetupView()
            case .scanning: ScanningView()
            case .results: ResultsView()
            case .cleaning: CleaningView()
            case .summary: SummaryView()
            }
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Find exact duplicate photos and videos")
                    .font(.largeTitle.weight(.semibold))
                Text("Doppio compares file contents byte by byte, never names. Nothing changes until you confirm, and files only ever go to the Trash.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 620)

            folderArea
                .frame(maxWidth: 680, minHeight: 180, maxHeight: 260)

            Form {
                Picker("Look at", selection: $model.includeAllTypes) {
                    Text("Photos and videos").tag(false)
                    Text("All files").tag(true)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Files read at once") {
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(value: $model.jobs, in: 1...16) { Text("\(model.jobs)").monospacedDigit() }
                        Text("Keep 1 for spinning hard disks; 2–4 for SSDs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Suggestions") {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Treat random-looking names as copies", isOn: $model.randomNamesAreCopies)
                        Text("Names like NBQE3618.jpg, made by some gallery and recovery apps, count as copies of a real-named file.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.columns)
            .frame(maxWidth: 560)

            Button {
                model.startScan()
            } label: {
                Text("Scan").frame(minWidth: 120)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.folders.isEmpty)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var folderArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Color.accentColor.opacity(0.08) : .clear))
            if model.folders.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Drop folders or drives here").font(.title3)
                    Button("Choose Folders…", action: chooseFolders)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.folders, id: \.self) { url in
                                HStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable().frame(width: 22, height: 22)
                                    Text(url.path).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        model.removeFolder(url)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove from the scan")
                                }
                            }
                        }
                        .padding(16)
                    }
                    Divider()
                    HStack {
                        Text("Drop more folders here, or").foregroundStyle(.secondary)
                        Button("Add Folder…", action: chooseFolders)
                    }
                    .padding(10)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addFolders(urls.filter(\.isFileURL))
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders or drives to scan for duplicates."
        if panel.runModal() == .OK { model.addFolders(panel.urls) }
    }
}

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.scanProgress
        VStack(spacing: 16) {
            Text(p?.phase.rawValue ?? "Starting…").font(.title2.weight(.medium))
            if let fraction = p?.fraction, p?.phase != .walking {
                ProgressView(value: fraction).frame(width: 420)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(detail(p)).monospacedDigit().foregroundStyle(.secondary)
            Text("Scanning only reads files. Nothing is changed.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ p: ScanProgress?) -> String {
        guard let p else { return " " }
        if p.phase == .walking { return "\(Format.count(p.filesDone, "file")) found" }
        var parts: [String] = []
        if p.bytesTotal > 0 { parts.append("\(Format.bytes(p.bytesDone)) of \(Format.bytes(p.bytesTotal))") }
        if p.filesTotal > 0 { parts.append("\(p.filesDone.formatted()) of \(p.filesTotal.formatted())") }
        return parts.joined(separator: " · ")
    }
}

struct CleaningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.cleanProgress
        VStack(spacing: 16) {
            Text(model.stopRequested ? "Stopping after the current file…" : "Moving copies to the Trash")
                .font(.title2.weight(.medium))
            ProgressView(value: p.map { Double($0.filesDone) / Double(max(1, $0.filesTotal)) } ?? 0)
                .frame(width: 420)
            Text(p.map { "\($0.filesDone.formatted()) of \(Format.count($0.filesTotal, "file"))" } ?? " ")
                .monospacedDigit().foregroundStyle(.secondary)
            Text("Before each file is moved, Doppio checks again that the copy it keeps is still there and byte-identical.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Stop After Current File") { model.stopClean() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.stopRequested)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
