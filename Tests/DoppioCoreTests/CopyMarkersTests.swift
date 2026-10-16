import Foundation
import Testing
@testable import DoppioCore

/// Table-driven tests for original detection. Add a row when you add a marker.
struct CopyMarkersTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let names: [String]
        /// Index of the file that should be kept, nil = ambiguous.
        let original: Int?
        var testDescription: String { names.joined(separator: " | ") }
    }

    static let cases: [Case] = [
        // Every marker in the table.
        Case(names: ["VID_20250822_205114.mp4", "VID_20250822_205114_1.mp4"], original: 0),
        Case(names: ["IMG_1234_2.jpg", "IMG_1234.jpg"], original: 1),
        Case(names: ["IMG_1234.jpg", "IMG_1234-1.jpg"], original: 0),
        Case(names: ["IMG_1234 (1).jpg", "IMG_1234.jpg"], original: 1),
        Case(names: ["IMG_1234.jpg", "IMG_1234 (1).jpg", "IMG_1234 (2).jpg"], original: 0),
        Case(names: ["sunset.heic", "sunset 2.heic"], original: 0),
        Case(names: ["photo.jpg", "photo copy.jpg"], original: 0),
        Case(names: ["photo.jpg", "photo copy.jpg", "photo copy 2.jpg"], original: 0),
        Case(names: ["photo - Copy.jpg", "photo.jpg"], original: 1),
        Case(names: ["photo.jpg", "photo - Copy (2).jpg"], original: 0),
        Case(names: ["foto.jpg", "foto - Copia.jpg"], original: 0),
        Case(names: ["foto.jpg", "foto - Copia (3).jpg"], original: 0),
        Case(names: ["foto.jpg", "foto copia.jpg", "foto copia 2.jpg"], original: 0),
        Case(names: ["Copy of beach.png", "beach.png"], original: 1),
        Case(names: ["mare.png", "Copia di mare.png"], original: 0),
        Case(names: [".Screenshot 2025-01-01 at 10.00.00.png", "Screenshot 2025-01-01 at 10.00.00.png"], original: 1),
        // Machine-made copies (phone backup / recovery dumps).
        Case(names: ["IMG_20221001_152443.jpg", "IMG_20221001_152443_1706717647603.jpg"], original: 0),
        Case(names: ["-1764628937-IMG_20221001_152443.jpg", "IMG_20221001_152443.jpg"], original: 1),
        Case(names: ["IMG_1.jpg", ".trashed-1764628937-IMG_1.jpg"], original: 0),
        Case(names: ["_.6a4158284c09f728615f25bee694b85a.png", "6a4158284c09f728615f25bee694b85a.png"], original: 1),
        Case(names: ["IMG_20221001_152443.jpg", ".IMG_20221001_152443.jpg", ".IMG_20221001_152443_1706717647603.jpg",
                     ".IMG_20221001_152443_1706912337610.jpg", "-1764628937-IMG_20221001_152443.jpg"], original: 0),
        Case(names: ["x.mp4", ".x_1_1706912521379.mp4", ".x_1.mp4"], original: 0),
        Case(names: ["_.IMG-20230617-WA0085_1707520856983.jpg", "IMG-20230617-WA0085.jpg"], original: 1),
        // Chained markers.
        Case(names: ["IMG_1.jpg", "IMG_1 (1) copy.jpg"], original: 0),
        Case(names: ["photo.jpg", "Copy of photo copy.jpg"], original: 0),
        // Case-insensitive, extension included.
        Case(names: ["IMG_7.JPG", "img_7 (1).jpg"], original: 0),
        Case(names: ["Photo.HEIC", "PHOTO COPY.heic"], original: 0),
        // Unicode NFD vs NFC.
        Case(names: ["Caffe\u{0300}.jpg", "Caff\u{00E8} (1).jpg"], original: 0),
        Case(names: ["Caff\u{00E8}.jpg", "Caffe\u{0300} copia.jpg"], original: 0),
        // When only copies are present, the least-derived one is kept.
        Case(names: ["photo copy.jpg", "photo copy 2.jpg"], original: 0),

        // Ambiguous: never guess.
        Case(names: ["VID_20250822_205114.mp4", "VID_20250822.mp4"], original: nil), // 6 digits: not a copy number
        Case(names: ["IMG_9999.DNG", "HBIK8661.DNG"], original: nil),
        Case(names: ["IMG_1.jpg", "IMG_1.jpg"], original: nil),                      // same name, different folders
        Case(names: ["IMG_1234 (1).jpg", "IMG_1234 (2).jpg"], original: nil),        // original missing
        Case(names: ["IMG_1.jpg", "IMG_1 (1).jpeg"], original: nil),                 // different extension
        Case(names: ["photo.jpg", "photo (1).png"], original: nil),
        Case(names: [".photo.jpg", "other.jpg"], original: nil),
        Case(names: ["photo.jpg", "photo.jpg", "photo copy.jpg"], original: nil),    // two originals
        Case(names: ["1.jpg", "_1.jpg"], original: nil),                             // stripping would leave nothing
        Case(names: ["Trip 2024.jpg", "Trip.jpg"], original: nil),                   // 4-digit " 2024" is not Finder's " 2"
        Case(names: ["holiday_copy.jpg", "holiday.jpg"], original: nil),             // "_copy" is not a marker
        // Timestamp markers only accept plausible epoch values (2017–2033).
        Case(names: ["IMG.jpg", "IMG_1234567890123.jpg"], original: nil),            // 13 digits but year 2009
        Case(names: ["IMG.jpg", "IMG_17067176476.jpg"], original: nil),              // 11 digits
        Case(names: ["IMG.jpg", "-1234567890-IMG.jpg"], original: nil),              // year 2009
        Case(names: ["IMG.jpg", "-17646289370-IMG.jpg"], original: nil),             // 11 digits
        // Both "trash" and "hidden" versions, but no plain one: no single original.
        Case(names: ["-1764628937-IMG_1.jpg", ".IMG_1.jpg", ".IMG_1_1706717647603.jpg"], original: nil),
        // Random-looking names are NOT copies under the default rules.
        Case(names: ["IMG-20241227-WA0019.jpg", "HKNM5184.JPG"], original: nil),
    ]

    @Test(arguments: [
        Case(names: ["IMG-20241227-WA0019.jpg", "HKNM5184.JPG"], original: 0),
        Case(names: ["RUHH4377.JPG", "IMG_20250402_191604.jpg", "RUHHE4377.JPG", "SZQU3028.JPG"], original: 1),
        Case(names: [".img-20220731-wa0020.jpg", "img-20220731-wa0020.jpg", "KBJF0274.jpg",
                     ".img-20220731-wa0020_1706650698131.jpg"], original: 1),
        Case(names: ["-1764496890-Screenshot_2025-01-21.jpg", "NBQE3618.jpg"], original: 0),
        Case(names: [".NBQE3618.jpg", "photo.jpg"], original: 1),           // hidden random name
        Case(names: ["HKNM5184.JPG", "RYND3759.JPG"], original: nil),       // only random names
        Case(names: ["a/IMG_1.jpg", "b/IMG_1.jpg", "XKCD1234.jpg"].map { ($0 as NSString).lastPathComponent },
             original: nil),                                                // two real originals remain
        Case(names: ["IMG_1.jpg", "AB1234.jpg"], original: nil),            // 2 letters: not random-looking
        Case(names: ["IMG_1.jpg", "ABCDEF1234.jpg"], original: nil),        // 6 letters
    ])
    func randomNamesAreCopiesWhenEnabled(_ c: Case) {
        #expect(CopyMarkers.originalIndex(names: c.names.map { [$0] }, randomNamesAreCopies: true) == c.original)
    }

    @Test(arguments: cases)
    func originalDetection(_ c: Case) {
        #expect(CopyMarkers.originalIndex(names: c.names.map { [$0] }) == c.original)
    }

    @Test func singleFileAloneIsNeverDerived() {
        // The classic false positive: underscores and digits that are not copy markers.
        #expect(CopyMarkers.strippedOnce(CopyMarkers.normalize("VID_20250822_205114.mp4")).isEmpty)
        #expect(!CopyMarkers.isDerived("VID_20250822_205114.mp4", fromAnyOf: ["vid_20250822.mp4", "vid.mp4"]))
    }

    @Test func hardLinkedFileCountsAllItsNames() {
        // One physical file with two names, plus a copy of it.
        let names = [["a.jpg", "a_link.jpg"], ["a copy.jpg"]]
        #expect(CopyMarkers.originalIndex(names: names) == 0)
        // A physical file is derived only if all of its names are.
        #expect(CopyMarkers.originalIndex(names: [["b.jpg"], ["b (1).jpg", "unrelated.jpg"]]) == nil)
    }

    @Test(arguments: [
        ("photo copy 2.jpg", ["photo copy.jpg", "photo.jpg"]),
        ("img_1234 (1).jpg", ["img_1234.jpg"]),
        (".hidden.png", ["hidden.png"]),
        ("copy of x.jpg", ["x.jpg"]),
        ("noext_1", ["noext"]),
    ])
    func strippedOnce(_ name: String, _ expected: [String]) {
        #expect(Set(CopyMarkers.strippedOnce(name)) == Set(expected))
    }

    @Test func everyTableRowHasAWorkingExample() {
        for marker in CopyMarkers.table {
            // Drop trailing annotations such as " (Finder)" that follow the extension.
            let example = marker.example.replacingOccurrences(of: #" \([^)]*\)$"#, with: "", options: .regularExpression)
            let stripped = CopyMarkers.strippedOnce(CopyMarkers.normalize(example))
            #expect(!stripped.isEmpty, "marker example \(marker.example) is not recognised")
        }
    }
}
