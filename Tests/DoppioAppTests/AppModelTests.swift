import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DoppioApp
@testable import DoppioCore

/// A small folder of real JPEGs: two obvious copies and two ambiguous groups.
struct PhotoFolder {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppio-app-tests-\(UUID().uuidString)/Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Backup"), withIntermediateDirectories: true)
        try jpeg("IMG_1234.jpg", hue: 0.08)
        try copy("IMG_1234.jpg", "IMG_1234 (1).jpg")
        try copy("IMG_1234.jpg", "Backup/IMG_1234 copy.jpg")
        try jpeg("VID_20250822_205114.jpg", hue: 0.55)
        try copy("VID_20250822_205114.jpg", "VID_20250822_205114_1.jpg")
        try jpeg("IMG_9999.jpg", hue: 0.33)
        try copy("IMG_9999.jpg", "HBIK8661.jpg")
        try jpeg("Beach.jpg", hue: 0.6)
        try copy("Beach.jpg", "Backup/Beach.jpg")
        try copy("Beach.jpg", "Backup/KQZT2210.jpg")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func path(_ relative: String) -> String { ScanRoots.realPath(root.path)! + "/" + relative }

    /// A real copy (copyItem would make an APFS clone, which frees almost nothing).
    private func copy(_ from: String, _ to: String) throws {
        try Data(contentsOf: root.appendingPathComponent(from)).write(to: root.appendingPathComponent(to))
    }

    /// A gradient "photo" with a sun, so thumbnails are recognisable.
    private func jpeg(_ name: String, hue: CGFloat) throws {
        let size = 480
        let ctx = CGContext(data: nil, width: size, height: size * 3 / 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let top = NSColor(hue: hue, saturation: 0.5, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: hue, saturation: 0.8, brightness: 0.5, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: .zero, options: [])
        ctx.setFillColor(NSColor.systemYellow.cgColor)
        ctx.fillEllipse(in: CGRect(x: 320, y: 230, width: 80, height: 80))
        let url = root.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:07:14 18:32:05"]
        CGImageDestinationAddImage(destination, ctx.makeImage()!, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

@MainActor
struct AppModelTests {
    func scanned(_ folder: PhotoFolder) async throws -> AppModel {
        let model = AppModel()
        model.addFolders([folder.root])
        let result = try await DuplicateFinder(options: ScanOptions(roots: model.folders)).run()
        model.show(result)
        return model
    }

    @Test func suggestionsArePreCheckedAndAmbiguousGroupsAreNot() async throws {
        let folder = try PhotoFolder()
        defer { folder.cleanup() }
        let model = try await scanned(folder)
        #expect(model.stage == .results)
        #expect(model.suggestedGroups.count == 2)
        #expect(model.reviewGroups.count == 2)
        #expect(model.suggestedGroups.allSatisfy(model.isSelected))
        #expect(model.reviewGroups.allSatisfy { model.status(of: $0) == .undecided && !model.isSelected($0) })
        let totals = model.totals
        #expect(totals.files == 3 && totals.suggestedFiles == 3 && totals.chosenFiles == 0)
    }

    @Test func uncheckingASuggestionKeepsAllItsFiles() async throws {
        let folder = try PhotoFolder()
        defer { folder.cleanup() }
        let model = try await scanned(folder)
        let group = try #require(model.suggestedGroups.first { $0.files.count == 3 })
        model.setSelected(group, false)
        #expect(model.totals.files == 1)
        #expect(!model.plans.contains { $0.group.id == group.id })
        model.selectAllSuggestions(false)
        #expect(model.plans.isEmpty)
        model.selectAllSuggestions(true)
        #expect(model.totals.files == 3)
    }

    @Test func reviewKeysChooseAndAdvance() async throws {
        let folder = try PhotoFolder()
        defer { folder.cleanup() }
        let model = try await scanned(folder)
        model.tab = .review
        #expect(model.reviewIndex == 0 && model.canUseReviewKeys)

        let first = try #require(model.currentReviewGroup)
        model.keep(fileAt: 1)
        #expect(model.status(of: first) == .keep(index: 1))
        #expect(model.reviewIndex == 1)
        let plan = try #require(model.plans.first { $0.group.id == first.id })
        #expect(plan.keep.path == first.files[1].path)
        #expect(plan.trash.count == first.files.count - 1)

        let second = try #require(model.currentReviewGroup)
        model.keepAll()
        #expect(model.status(of: second) == .keepAll)
        #expect(model.reviewIndex == 1) // last group: stays put
        model.keep(fileAt: 7) // no such file: nothing happens
        #expect(model.status(of: second) == .keepAll)

        model.previous()
        #expect(model.reviewIndex == 0)
        model.keepAll() // change of mind
        #expect(model.status(of: first) == .keepAll)
        #expect(model.totals.chosenFiles == 0)
        #expect(model.decidedReviewCount == 2)
    }

    @Test func refusesFilesAndPackagesAsFolders() throws {
        let folder = try PhotoFolder()
        defer { folder.cleanup() }
        let model = AppModel()
        model.addFolders([folder.root.appendingPathComponent("Beach.jpg")])
        #expect(model.folders.isEmpty && model.alert != nil)

        let library = folder.root.appendingPathComponent("Old.photoslibrary/originals")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        model.alert = nil
        model.addFolders([library])
        #expect(model.folders.isEmpty && model.alert != nil)

        model.addFolders([folder.root, folder.root])
        #expect(model.folders.count == 1)
    }
}

/// Stand-in for the system Trash: a folder next to the test photos. Never overwrites.
struct TestTrash: TrashMover {
    let folder: URL

    func moveToTrash(_ path: String) throws -> String? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString + "-" + (path as NSString).lastPathComponent).path
        guard renamex_np(path, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        return destination
    }
}

extension PhotoFolder {
    var scratch: URL { root.deletingLastPathComponent() }

    /// Points the model's cleaner and logs at folders outside the scanned one.
    @MainActor func isolate(_ model: AppModel) {
        let trash = TestTrash(folder: scratch.appendingPathComponent("Trash"))
        model.logDirectory = scratch.appendingPathComponent("Logs")
        model.makeCleaner = { roots, logs in Cleaner(roots: roots, logDirectory: logs, mover: trash) }
    }
}

@MainActor
struct AppFlowTests {
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func cleanThenPutEverythingBack() async throws {
        let folder = try PhotoFolder()
        defer { folder.cleanup() }
        let model = AppModel()
        folder.isolate(model)
        model.addFolders([folder.root])
        model.startScan()
        try await waitUntil { model.stage == .results }

        model.tab = .review
        model.keep(fileAt: 0) // one ambiguous group decided, the other left undecided
        #expect(model.totals.files == 5)
        model.startClean()
        try await waitUntil { model.stage == .summary }

        let clean = try #require(model.cleanResult)
        #expect(clean.trashed.count == 5 && clean.notMoved.isEmpty)
        #expect(clean.log.jsonl.path.hasPrefix(folder.scratch.path))
        // Every group still has a file; the undecided group is untouched.
        for group in model.result!.groups {
            #expect(group.files.contains { FileManager.default.fileExists(atPath: $0.path) })
        }
        let undecided = model.reviewGroups[1]
        #expect(undecided.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        model.restoreAll()
        try await waitUntil { !model.isRestoring }
        #expect(model.restoreResult?.restored.count == 5)
        for group in model.result!.groups {
            #expect(group.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
    }

    @Test func cancellingTheScanChangesNothing() async throws {
        let folder = try PhotoFolder()
        defer { folder.cleanup() }
        let model = AppModel()
        model.addFolders([folder.root])
        model.startScan()
        model.cancelScan()
        try await waitUntil { model.stage != .scanning }
        #expect(model.stage == .setup || model.stage == .results)
        #expect(model.cleanResult == nil)
    }
}
