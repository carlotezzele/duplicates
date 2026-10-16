import Darwin
import Foundation
@testable import DoppioCore

/// Builds a temporary tree that exercises every case Doppio must handle.
/// Layout is described next to each `write` call; `expectedGroups` lists the result.
struct Fixture {
    let base: URL
    /// The folder that gets scanned.
    let root: URL
    /// A sibling folder outside the scan, for reports.
    let outside: URL

    static let nfdName = "Caffe\u{0300}.jpg"          // "Caffè.jpg", decomposed
    static let nfcCopyName = "Caff\u{00E8} (1).jpg"     // "Caffè (1).jpg", precomposed

    /// Expected duplicate groups for a media-only scan: relative paths → suggested keep (nil = ambiguous).
    static let expectedGroups: [Set<String>: String?] = [
        ["phone/VID_20250822_205114.mp4", "phone/VID_20250822_205114_1.mp4"]: "phone/VID_20250822_205114.mp4",
        ["phone/IMG_1234.jpg", "backup/IMG_1234 (1).jpg"]: "phone/IMG_1234.jpg",
        ["mac/photo.jpg", "mac/photo copy.jpg", "mac/photo copy 2.jpg"]: "mac/photo.jpg",
        ["mac/Screenshot 2025-01-01 at 10.00.00.png", "mac/.Screenshot 2025-01-01 at 10.00.00.png"]:
            "mac/Screenshot 2025-01-01 at 10.00.00.png",
        ["export/beach.png", "export/Copy of beach.png"]: "export/beach.png",
        ["export/mare.png", "export/Copia di mare.png"]: "export/mare.png",
        ["win/foto.jpg", "win/foto - Copia.jpg"]: "win/foto.jpg",
        ["win/pic.jpg", "win/pic - Copy.jpg"]: "win/pic.jpg",
        ["finder/sunset.heic", "finder/sunset 2.heic"]: "finder/sunset.heic",
        ["it/gita.jpg", "it/gita copia.jpg", "it/gita copia 2.jpg", "it/gita-1.jpg"]: "it/gita.jpg",
        ["case/IMG_7.JPG", "case/IMG_7 (1).jpg"]: "case/IMG_7.JPG",
        ["accents/\(nfdName)", "accents/\(nfcCopyName)"]: "accents/\(nfdName)",
        ["hl2/a.jpg", "hl2/a copy.jpg"]: "hl2/a.jpg",
        ["clone/vacation.jpg", "clone/vacation copy.jpg"]: "clone/vacation.jpg",
        ["raw/IMG_9999.DNG", "raw/HBIK8661.DNG"]: nil,
        ["a/IMG_1.jpg", "b/IMG_1.jpg"]: nil,
    ]

    /// Extra group found only with "all types".
    static let allTypesExtraGroups: [Set<String>: String?] = [
        ["docs/notes.txt", "docs/notes copy.txt"]: "docs/notes.txt",
    ]

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppio-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("tree", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try build()
    }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    /// Resolved (realpath) form, as the scanner reports it.
    func realPath(_ relative: String) -> String {
        ScanRoots.realPath(root.path)! + "/" + relative
    }

    func relative(_ path: String) -> String {
        String(path.dropFirst(ScanRoots.realPath(root.path)!.count + 1))
    }

    func cleanup() {
        chmod(path("locked/secret.mp4"), 0o644)
        chmod(path("lockeddir"), 0o755)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Building

    private func build() throws {
        let vid = bytes(seed: 1, count: 300_000)
        try write("phone/VID_20250822_205114.mp4", vid)
        try write("phone/VID_20250822_205114_1.mp4", vid)

        let img = bytes(seed: 2, count: 5_000)
        try write("phone/IMG_1234.jpg", img)
        try write("backup/IMG_1234 (1).jpg", img)

        let photo = bytes(seed: 3, count: 7_000)
        try write("mac/photo.jpg", photo)
        try write("mac/photo copy.jpg", photo)
        try write("mac/photo copy 2.jpg", photo)
        try write("mac/._photo.jpg", photo)            // AppleDouble: ignored
        try write("mac/._photo copy.jpg", photo)       // AppleDouble: ignored
        try write("mac/.DS_Store", bytes(seed: 90, count: 600))
        try write("phone/.DS_Store", bytes(seed: 90, count: 600))
        try write("Lib.photoslibrary/originals/A/photo.jpg", photo) // package: never scanned
        try write(".Trashes/501/photo.jpg", photo)                  // system folder: never scanned

        let shot = bytes(seed: 4, count: 9_000)
        try write("mac/Screenshot 2025-01-01 at 10.00.00.png", shot)
        try write("mac/.Screenshot 2025-01-01 at 10.00.00.png", shot) // hidden copy

        try pair("export/beach.png", "export/Copy of beach.png", seed: 5)
        try pair("export/mare.png", "export/Copia di mare.png", seed: 6)
        try pair("win/foto.jpg", "win/foto - Copia.jpg", seed: 7)
        try pair("win/pic.jpg", "win/pic - Copy.jpg", seed: 8)
        try pair("finder/sunset.heic", "finder/sunset 2.heic", seed: 9)

        let gita = bytes(seed: 10, count: 4_100)
        for name in ["gita.jpg", "gita copia.jpg", "gita copia 2.jpg", "gita-1.jpg"] {
            try write("it/" + name, gita)
        }

        try pair("case/IMG_7.JPG", "case/IMG_7 (1).jpg", seed: 11)

        // Arbitrary names, identical content: ambiguous.
        let raw = bytes(seed: 12, count: 200_000)
        try write("raw/IMG_9999.DNG", raw)
        try write("raw/HBIK8661.DNG", raw)

        // Same name, same content, different folders: ambiguous.
        try pair("a/IMG_1.jpg", "b/IMG_1.jpg", seed: 13)
        // Same name and size, different content: not duplicates.
        try write("a/IMG_2.jpg", bytes(seed: 14, count: 3_000))
        try write("b/IMG_2.jpg", bytes(seed: 15, count: 3_000))

        // Big files differing only in the last byte (quick hash catches it)
        // and only in a middle byte (quick hash matches, full hash catches it).
        let big = bytes(seed: 16, count: 300_000)
        try write("near/big_a.mov", big)
        try write("near/big_b.mov", flipping(big, at: big.count - 1))
        let mid = bytes(seed: 17, count: 300_000)
        try write("near/mid_a.mov", mid)
        try write("near/mid_b.mov", flipping(mid, at: mid.count / 2))

        // Same size, different content.
        try write("samesize/x.jpg", bytes(seed: 18, count: 1_000))
        try write("samesize/y.jpg", bytes(seed: 19, count: 1_000))

        // Hard links: one file, two names. Never a duplicate of itself.
        try write("hl/orig.jpg", bytes(seed: 20, count: 2_000))
        try hardLink("hl/orig.jpg", "hl/link.jpg")
        // Hard-linked file plus an independent copy: one group of two physical files.
        let hl2 = bytes(seed: 21, count: 2_100)
        try write("hl2/a.jpg", hl2)
        try hardLink("hl2/a.jpg", "hl2/a_link.jpg")
        try write("hl2/a copy.jpg", hl2)

        // APFS clone (what Finder's Duplicate makes): trashing it frees ~nothing.
        try write("clone/vacation.jpg", bytes(seed: 22, count: 500_000))
        guard clonefile(path("clone/vacation.jpg"), path("clone/vacation copy.jpg"), 0) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        // Symlinks: never followed.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sym"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path("sym/link.jpg"), withDestinationPath: "../mac/photo.jpg")
        try FileManager.default.createSymbolicLink(atPath: path("sym/dirlink"), withDestinationPath: "../mac")

        // Zero-byte files: ignored.
        try write("empty/e1.jpg", Data())
        try write("empty/e2.jpg", Data())

        // NFD original, NFC copy.
        try pair("accents/\(Fixture.nfdName)", "accents/\(Fixture.nfcCopyName)", seed: 23)

        // Not media.
        try pair("docs/notes.txt", "docs/notes copy.txt", seed: 24)

        // Unreadable file with the same content as the VID pair, and an unreadable folder.
        try write("locked/secret.mp4", vid)
        chmod(path("locked/secret.mp4"), 0)
        try write("lockeddir/hidden.jpg", img)
        chmod(path("lockeddir"), 0)
    }

    private func pair(_ a: String, _ b: String, seed: UInt64) throws {
        let data = bytes(seed: seed, count: 4_000 + Int(seed) * 37)
        try write(a, data)
        try write(b, data)
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func hardLink(_ existing: String, _ new: String) throws {
        try FileManager.default.linkItem(atPath: path(existing), toPath: path(new))
    }

    private func flipping(_ data: Data, at index: Int) -> Data {
        var copy = data
        copy[index] ^= 0xFF
        return copy
    }
}

/// Deterministic pseudo-random bytes (SplitMix64).
func bytes(seed: UInt64, count: Int) -> Data {
    var state = seed &* 0x9E37_79B9_7F4A_7C15
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        var i = 0
        while i < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            for b in 0..<8 where i < count {
                raw[i] = UInt8(truncatingIfNeeded: z >> (b * 8))
                i += 1
            }
        }
    }
    return data
}
