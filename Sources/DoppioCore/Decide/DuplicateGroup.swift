import Foundation

/// One physical file (one device+inode) in a duplicate group.
public struct DuplicateFile: Hashable, Sendable, Identifiable {
    /// The record for the file's primary path (alphabetically first, if hard-linked).
    public let record: FileRecord
    /// Other paths of the same physical file found in the scan (hard links).
    public let hardLinkPaths: [String]
    /// Bytes not shared with APFS clones, if the volume reports it.
    public let privateSize: Int64?
    /// False when clones might share storage and the private size is unknown.
    public let spaceIsExact: Bool

    public var id: String { record.path }
    public var path: String { record.path }
    public var allPaths: [String] { [record.path] + hardLinkPaths }
    public var allNames: [String] { allPaths.map { ($0 as NSString).lastPathComponent } }

    /// More than one link (inside or outside the scan): trashing one path frees nothing
    /// and the "copy" is the very same file, so Doppio never offers it for the Trash.
    public var isHardLinked: Bool { record.linkCount > 1 || !hardLinkPaths.isEmpty }
    public var canBeTrashed: Bool { !isHardLinked }

    /// Space freed if this file were trashed: its size, or less if it shares storage
    /// with APFS clones (private size). Expressed like Finder sizes, not disk blocks.
    public var reclaimableSize: Int64 {
        guard canBeTrashed else { return 0 }
        return min(record.size, privateSize ?? record.size)
    }
}

public enum Suggestion: Hashable, Sendable {
    case keep(path: String)
    case ambiguous(reason: String)

    public var keptPath: String? {
        if case let .keep(path) = self { return path }
        return nil
    }

    public var isAutoResolvable: Bool { keptPath != nil }
}

/// Files whose contents are 100% identical (same size, same SHA-256, byte-compared).
public struct DuplicateGroup: Hashable, Sendable, Identifiable {
    public let sha256: String
    public let size: Int64
    /// Sorted by path. Always at least two.
    public let files: [DuplicateFile]
    public let suggestion: Suggestion

    public var id: String { sha256 }

    /// Files the suggestion would move to the Trash (empty for ambiguous groups).
    public var suggestedForTrash: [DuplicateFile] {
        guard let kept = suggestion.keptPath else { return [] }
        return files.filter { $0.path != kept }
    }

    /// Space freed by keeping just one copy: the suggestion's choice, or for ambiguous
    /// groups the best case (keep the copy that frees least when deleted).
    public var reclaimableSize: Int64 {
        if suggestion.isAutoResolvable { return suggestedForTrash.reduce(0) { $0 + $1.reclaimableSize } }
        let trashable = files.filter(\.canBeTrashed).map(\.reclaimableSize)
        let total = trashable.reduce(0, +)
        return trashable.count == files.count ? total - (trashable.max() ?? 0) : total
    }

    public var spaceIsExact: Bool { files.allSatisfy(\.spaceIsExact) }
}

/// Optional extra rules for automatic suggestions. Defaults are the strict rules.
public struct SuggestionRules: Hashable, Sendable {
    /// Treat random-looking names ("NBQE3618.jpg") as copies of a real-named file.
    public var randomNamesAreCopies: Bool

    public init(randomNamesAreCopies: Bool = false) {
        self.randomNamesAreCopies = randomNamesAreCopies
    }
}

public enum Suggester {
    /// Picks the obvious original, or explains why the group needs a human.
    public static func suggest(for files: [DuplicateFile], rules: SuggestionRules = .init()) -> Suggestion {
        guard let index = CopyMarkers.originalIndex(names: files.map(\.allNames),
                                                    randomNamesAreCopies: rules.randomNamesAreCopies) else {
            return .ambiguous(reason: "No single file is clearly the original")
        }
        let original = files[index]
        let copies = files.indices.filter { $0 != index }.map { files[$0] }
        if let linked = copies.first(where: { !$0.canBeTrashed }) {
            return .ambiguous(reason: "\(linked.record.name) is a hard link, which Doppio never trashes")
        }
        return .keep(path: original.path)
    }
}
