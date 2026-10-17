import DoppioCore
import SwiftUI

/// Side-by-side review of the groups Doppio could not decide. Nothing is pre-selected:
/// a file is only marked for the Trash after the user picks the one to keep.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.reviewGroups.isEmpty {
            ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                   description: Text("Every group has an obvious original."))
        } else {
            HSplitView {
                List(selection: $model.reviewIndex) {
                    Section("\(model.decidedReviewCount.formatted()) of \(model.reviewGroups.count.formatted()) decided") {
                        ForEach(Array(model.reviewGroups.enumerated()), id: \.element.id) { index, group in
                            ReviewListRow(group: group, status: model.status(of: group)).tag(index)
                        }
                    }
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

                if let group = model.currentReviewGroup, let index = model.reviewIndex {
                    GroupReview(group: group, index: index)
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Select a group").foregroundStyle(.secondary)
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct ReviewListRow: View {
    let group: DuplicateGroup
    let status: ReviewStatus

    var body: some View {
        HStack(spacing: 8) {
            Thumbnail(path: group.files[0].path, side: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.name(group.files[0].path)).lineLimit(1).truncationMode(.middle)
                Text("\(group.files.count) files · \(Format.bytes(group.size)) each")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .undecided: EmptyView()
            case .keepAll: Image(systemName: "equal.circle").foregroundStyle(.secondary).help("Keeping all files")
            case let .keep(index): Text("Keep \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
        }
    }
}

struct GroupReview: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup
    let index: Int

    var body: some View {
        let status = model.status(of: group)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group \(index + 1) of \(model.reviewGroups.count.formatted())").font(.headline)
                    Text("\(group.files.count) identical files · \(Format.bytes(group.size)) each · \(reason)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.previous() } label: { Label("Previous", systemImage: "chevron.left") }
                    .disabled(index == 0)
                    .help("Previous group (←)")
                Button { model.keepAll() } label: { Text("Keep All") }
                    .help("Keep every file in this group (K)")
                Button { model.next() } label: { Label("Next", systemImage: "chevron.right") }
                    .labelStyle(.titleAndIcon)
                    .disabled(index + 1 >= model.reviewGroups.count)
                    .help("Next group (→)")
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)], spacing: 16) {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { i, file in
                        FileCard(file: file, number: i + 1, role: role(of: i, file: file, status: status))
                    }
                }
                .padding(16)
            }
            Divider()
            Text(hint(status))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(10)
        }
    }

    private var reason: String {
        if case let .ambiguous(reason) = group.suggestion { return reason }
        return ""
    }

    private func role(of i: Int, file: DuplicateFile, status: ReviewStatus) -> FileCard.Role {
        switch status {
        case .undecided: file.canBeTrashed ? .undecided : .hardLink
        case .keepAll: .keep
        case let .keep(kept): i == kept ? .keep : (file.canBeTrashed ? .trash : .hardLink)
        }
    }

    private func hint(_ status: ReviewStatus) -> String {
        switch status {
        case .undecided:
            "Press 1–\(min(9, group.files.count)) (or click Keep This) to keep a file; the others go to the Trash. K keeps all · ← → move between groups · Space opens Quick Look"
        case .keepAll:
            "Keeping all files in this group. Pick a file to change your mind."
        case let .keep(kept):
            "Keeping file \(kept + 1). The other copies will go to the Trash when you confirm."
        }
    }
}

struct FileCard: View {
    enum Role { case undecided, keep, trash, hardLink }
    @Environment(AppModel.self) private var model
    let file: DuplicateFile
    let number: Int
    let role: Role

    var body: some View {
        let focused = model.focusedPath == file.path
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                Thumbnail(path: file.path, side: 200)
                    .opacity(role == .trash ? 0.5 : 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("\(number)")
                        .font(.headline.monospacedDigit())
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                    Spacer()
                    badge
                }
                .padding(8)
            }
            .onTapGesture(count: 2) { model.previewURL = URL(fileURLWithPath: file.path) }

            VStack(alignment: .leading, spacing: 3) {
                Text(Format.name(file.path)).font(.headline).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                Text(Format.folder(file.path)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(Format.folder(file.path))
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow { Text("Size").foregroundStyle(.secondary); Text(Format.bytes(file.record.size)) }
                GridRow { Text("Taken").foregroundStyle(.secondary); CaptureDateText(path: file.path) }
                GridRow { Text("Created").foregroundStyle(.secondary); Text(Format.date(file.record.created.date)) }
                GridRow { Text("Modified").foregroundStyle(.secondary); Text(Format.date(file.record.modified.date)) }
            }
            .font(.callout)
            if file.isHardLinked {
                Text("This file has hard links, so Doppio never moves it to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    model.focusedPath = file.path
                    model.keep(fileAt: number - 1)
                } label: {
                    Text(number <= 9 ? "Keep This  (\(number))" : "Keep This").frame(maxWidth: .infinity)
                }
                .disabled(role == .keep)
                Button {
                    model.reveal(file.path)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Reveal in Finder (⌘R)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor(focused: focused), lineWidth: role == .keep || focused ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture { model.focusedPath = file.path }
    }

    @ViewBuilder private var badge: some View {
        switch role {
        case .undecided: EmptyView()
        case .keep: Badge(text: "Keep", color: .green, systemImage: "checkmark")
        case .trash: Badge(text: "To Trash", color: .red, systemImage: "trash")
        case .hardLink: Badge(text: "Hard link, stays", color: .gray)
        }
    }

    private func borderColor(focused: Bool) -> Color {
        if role == .keep { return .green }
        if focused { return .accentColor }
        return Color.secondary.opacity(0.25)
    }
}
