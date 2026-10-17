import DoppioCore
import SwiftUI

/// Groups with an obvious original. All are pre-checked; unchecking a group keeps all its files.
struct SuggestedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.suggestedGroups.isEmpty {
            ContentUnavailableView("No automatic suggestions",
                                   systemImage: "checkmark.circle",
                                   description: Text("No group has a single obvious original. See “Needs Your Choice”."))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Toggle(isOn: Binding(get: { allSelected }, set: { model.selectAllSuggestions($0) })) {
                        Text("\(model.selectedSuggestionCount.formatted()) of \(Format.count(model.suggestedGroups.count, "group")) selected")
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text("In each group Doppio keeps the file whose name has no copy marker (“copy”, “(1)”, “_1”, …).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                Divider()
                List(model.suggestedGroups) { group in
                    SuggestedRow(group: group)
                }
                .listStyle(.inset)
            }
        }
    }

    private var allSelected: Bool { model.selectedSuggestionCount == model.suggestedGroups.count }
}

struct SuggestedRow: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    @ViewState private var expanded = false

    var body: some View {
        let kept = group.suggestion.keptPath ?? ""
        let copies = group.suggestedForTrash
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                FileLine(path: kept, role: .keep)
                ForEach(copies) { FileLine(path: $0.path, role: model.isSelected(group) ? .trash : .stays) }
            }
            .padding(.leading, 4)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { model.isSelected(group) }, set: { model.setSelected(group, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Thumbnail(path: kept, side: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.name(kept)).lineLimit(1).truncationMode(.middle)
                    Text(Format.folder(kept)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("+\(Format.count(copies.count, "copy", plural: "copies"))")
                    .foregroundStyle(.secondary)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.bytes(copies.reduce(0) { $0 + $1.record.size }))
                        .monospacedDigit()
                    if group.reclaimableSize < copies.reduce(0, { $0 + $1.record.size }) / 2 {
                        Text("frees \(Format.bytes(group.reclaimableSize)): APFS clones share storage")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 80, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
        }
    }
}

struct FileLine: View {
    enum Role { case keep, trash, stays }
    @Environment(AppModel.self) private var model
    let path: String
    let role: Role

    var body: some View {
        HStack(spacing: 8) {
            switch role {
            case .keep: Badge(text: "Keep", color: .green, systemImage: "checkmark")
            case .trash: Badge(text: "Trash", color: .red, systemImage: "trash")
            case .stays: Badge(text: "Stays", color: .gray)
            }
            Text(path)
                .font(.callout)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            RevealButton(path: path)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.focusedPath == path ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.previewURL = URL(fileURLWithPath: path) }
        .onTapGesture { model.focusedPath = path }
        .help("Click to select (Space for Quick Look); double-click to preview")
    }
}
