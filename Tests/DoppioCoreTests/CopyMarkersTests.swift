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
    ]

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
            let example = marker.example.replacingOccurrences(of: " (Finder)", with: "")
            let stripped = CopyMarkers.strippedOnce(CopyMarkers.normalize(example))
            #expect(!stripped.isEmpty, "marker example \(marker.example) is not recognised")
        }
    }
}
