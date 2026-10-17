import Foundation

/// What to do with one duplicate group: the file that stays and the files that go to the
/// Trash. Building a plan enforces the structural invariants (the kept file belongs to the
/// group and is never in the trash list, hard links are never trashed); `SafetyGuard`
/// re-checks the disk right before each file is moved.
public struct TrashPlan: Sendable, Hashable {
    public let group: DuplicateGroup
    public let keep: DuplicateFile
    public let trash: [DuplicateFile]

    /// Keep `path`; every other file that can be trashed goes. Hard-linked files stay put.
    public init(group: DuplicateGroup, keeping path: String) throws(PlanError) {
        let others = group.files.filter { $0.path != path && $0.canBeTrashed }.map(\.path)
        try self.init(group: group, keep: path, trash: others)
    }

    public init(group: DuplicateGroup, keep path: String, trash paths: [String]) throws(PlanError) {
        guard let kept = group.files.first(where: { $0.path == path }) else { throw .keptFileNotInGroup(path) }
        guard Set(paths).count == paths.count else { throw .listedTwice }
        var files: [DuplicateFile] = []
        for candidate in paths {
            guard candidate != path else { throw .wouldTrashKeptFile(candidate) }
            guard let file = group.files.first(where: { $0.path == candidate }) else { throw .notInGroup(candidate) }
            guard file.canBeTrashed else { throw .hardLinked(candidate) }
            files.append(file)
        }
        guard !files.isEmpty else { throw .nothingToTrash }
        self.group = group
        keep = kept
        trash = files
    }

    /// The automatic suggestion, or nil for an ambiguous group.
    public static func suggested(for group: DuplicateGroup) -> TrashPlan? {
        guard let kept = group.suggestion.keptPath else { return nil }
        return try? TrashPlan(group: group, keeping: kept)
    }

    public var bytes: Int64 { trash.reduce(0) { $0 + $1.record.size } }
    /// Space freed once the Trash is emptied (APFS clones free less than their size).
    public var reclaimableBytes: Int64 { trash.reduce(0) { $0 + $1.reclaimableSize } }
    /// Files that are neither kept nor trashed (hard links, which Doppio never trashes).
    public var untouched: [DuplicateFile] {
        group.files.filter { file in file.path != keep.path && !trash.contains { $0.path == file.path } }
    }
}

public enum PlanError: Error, Sendable, Hashable, CustomStringConvertible {
    case keptFileNotInGroup(String)
    case notInGroup(String)
    case wouldTrashKeptFile(String)
    case hardLinked(String)
    case listedTwice
    case nothingToTrash

    public var description: String {
        switch self {
        case let .keptFileNotInGroup(p): "\(p) is not in this duplicate group"
        case let .notInGroup(p): "\(p) is not in this duplicate group"
        case let .wouldTrashKeptFile(p): "\(p) is the file being kept; it can't also go to the Trash"
        case let .hardLinked(p): "\(p) is a hard link; Doppio never trashes hard links"
        case .listedTwice: "a file is listed twice"
        case .nothingToTrash: "every other file in this group is a hard link, so there is nothing to move to the Trash"
        }
    }
}

/// Decisions collected from the user (CLI or app) before anything is trashed.
/// Nothing in an ambiguous group is ever selected unless `keep(_:in:)` is called for it.
public struct CleanSelection: Sendable {
    private var plans: [String: TrashPlan] = [:] // by group id

    public init() {}

    /// Selects the automatic suggestion for every auto-resolvable group. Ambiguous groups are left alone.
    public mutating func acceptSuggestions(in groups: [DuplicateGroup]) {
        for group in groups {
            if let plan = TrashPlan.suggested(for: group) { plans[group.id] = plan }
        }
    }

    public mutating func keep(_ path: String, in group: DuplicateGroup) throws(PlanError) {
        plans[group.id] = try TrashPlan(group: group, keeping: path)
    }

    /// Keep every file in the group.
    public mutating func skip(_ group: DuplicateGroup) {
        plans[group.id] = nil
    }

    public func plan(for group: DuplicateGroup) -> TrashPlan? { plans[group.id] }

    /// Selected plans, in the order of `groups`.
    public func plans(in groups: [DuplicateGroup]) -> [TrashPlan] {
        groups.compactMap { plans[$0.id] }
    }

    public var isEmpty: Bool { plans.isEmpty }
}
