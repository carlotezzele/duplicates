import Foundation

/// Recognises names like "IMG_1234 (1).jpg" as copies of "IMG_1234.jpg".
///
/// Everything lives in `table`: to support a new marker, add one row (and a test row
/// in CopyMarkersTests). Patterns are case-insensitive and apply to the name *without*
/// its extension, except `.leadingDot`, which applies to the whole name.
///
/// Stripping a marker never on its own makes a file a copy: the stripped name must also
/// be the name of another file in the same duplicate group (see `originalIndex`).
public enum CopyMarkers {
    public enum Position: Sendable {
        case suffix      // pattern must match at the end of the stem
        case prefix      // pattern must match at the start of the stem
        case leadingDot  // hidden copy: ".name.jpg" of "name.jpg"
    }

    public struct Marker: Sendable {
        public let example: String
        public let position: Position
        /// Regex fragment for the marker itself; anchors are added from `position`.
        public let pattern: String
    }

    /// Numbered markers accept 1–3 digits, so date/time parts such as "_205114"
    /// in "VID_20250822_205114" are never read as a copy number.
    public static let table: [Marker] = [
        Marker(example: "IMG_1234_1.jpg", position: .suffix, pattern: #"_\d{1,3}"#),
        Marker(example: "IMG_1234-1.jpg", position: .suffix, pattern: #"-\d{1,3}"#),
        Marker(example: "IMG_1234 (1).jpg", position: .suffix, pattern: #" \(\d{1,3}\)"#),
        Marker(example: "IMG_1234 2.jpg (Finder)", position: .suffix, pattern: #" \d{1,3}"#),
        Marker(example: "photo copy.jpg", position: .suffix, pattern: #" copy"#),
        Marker(example: "photo copy 2.jpg", position: .suffix, pattern: #" copy \d{1,3}"#),
        Marker(example: "photo - Copy.jpg", position: .suffix, pattern: #" - copy"#),
        Marker(example: "photo - Copy (2).jpg", position: .suffix, pattern: #" - copy \(\d{1,3}\)"#),
        Marker(example: "foto - Copia.jpg", position: .suffix, pattern: #" - copia"#),
        Marker(example: "foto - Copia (2).jpg", position: .suffix, pattern: #" - copia \(\d{1,3}\)"#),
        Marker(example: "foto copia.jpg", position: .suffix, pattern: #" copia"#),
        Marker(example: "foto copia 2.jpg", position: .suffix, pattern: #" copia \d{1,3}"#),
        Marker(example: "Copy of photo.jpg", position: .prefix, pattern: #"copy of "#),
        Marker(example: "Copia di foto.jpg", position: .prefix, pattern: #"copia di "#),
        Marker(example: ".photo.jpg", position: .leadingDot, pattern: #"\."#),
    ]

    private struct Compiled: @unchecked Sendable {
        let position: Position
        let regex: NSRegularExpression
    }

    private static let compiled: [Compiled] = table.map { marker in
        let anchored = switch marker.position {
        case .suffix: "(?:\(marker.pattern))$"
        case .prefix, .leadingDot: "^(?:\(marker.pattern))"
        }
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: anchored, options: [.caseInsensitive])
        return Compiled(position: marker.position, regex: regex)
    }

    /// Unicode NFC + lowercase: the form used for every name comparison.
    public static func normalize(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Every name obtained by removing exactly one marker. Input and output are normalized.
    public static func strippedOnce(_ normalizedName: String) -> [String] {
        let (stem, ext) = splitExtension(normalizedName)
        var results: [String] = []
        for marker in compiled {
            switch marker.position {
            case .suffix, .prefix:
                let range = NSRange(stem.startIndex..., in: stem)
                guard let match = marker.regex.firstMatch(in: stem, range: range),
                      let r = Range(match.range, in: stem) else { continue }
                var newStem = stem
                newStem.removeSubrange(r)
                if newStem.isEmpty || newStem == "." { continue }
                results.append(newStem + ext)
            case .leadingDot:
                let range = NSRange(normalizedName.startIndex..., in: normalizedName)
                guard marker.regex.firstMatch(in: normalizedName, range: range) != nil else { continue }
                let rest = String(normalizedName.dropFirst())
                if rest.isEmpty || rest.hasPrefix(".") || splitExtension(rest).stem.isEmpty { continue }
                results.append(rest)
            }
        }
        return results
    }

    /// True if removing one or more markers from `name` yields a name in `others`.
    public static func isDerived(_ name: String, fromAnyOf others: Set<String>) -> Bool {
        var frontier = [normalize(name)]
        var seen = Set(frontier)
        while let current = frontier.popLast() {
            for candidate in strippedOnce(current) where seen.insert(candidate).inserted {
                if others.contains(candidate) { return true }
                frontier.append(candidate)
            }
        }
        return false
    }

    /// Given the names of each distinct file in a duplicate group (a file with hard links
    /// has several names), returns the index of the one file that is clearly the original,
    /// or nil if the group is ambiguous.
    ///
    /// A file is a derived copy if every one of its names, after stripping markers,
    /// matches the name of ANOTHER file in the group. The original is the single file
    /// that is not derived, and only if every other file is derived.
    public static func originalIndex(names: [[String]]) -> Int? {
        let normalized = names.map { Set($0.map(normalize)) }
        var originals: [Int] = []
        for (i, own) in normalized.enumerated() {
            var others = Set<String>()
            for (j, theirs) in normalized.enumerated() where j != i { others.formUnion(theirs) }
            let derived = !own.isEmpty && own.allSatisfy { isDerived($0, fromAnyOf: others) }
            if !derived { originals.append(i) }
        }
        return originals.count == 1 ? originals[0] : nil
    }

    /// "photo.final.JPG" → ("photo.final", ".jpg"); names without an extension → (name, "").
    static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
