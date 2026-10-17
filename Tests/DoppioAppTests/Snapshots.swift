import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DoppioApp
@testable import DoppioCore

/// Renders the app's screens offscreen to PNGs for a visual check, without needing
/// screen-recording permission. Opt-in: DOPPIO_SNAPSHOTS=<folder> make test
@MainActor
struct Snapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["DOPPIO_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderScreens() async throws {
        let out = URL(fileURLWithPath: Self.folder!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let photos = try PhotoFolder()
        defer { photos.cleanup() }

        let model = AppModel()
        model.addFolders([photos.root])
        try await render(model, to: out.appendingPathComponent("1-setup.png"))

        let result = try await DuplicateFinder(options: ScanOptions(roots: model.folders)).run()
        model.show(result)
        try await render(model, to: out.appendingPathComponent("2-suggested.png"))

        model.tab = .review
        try await render(model, to: out.appendingPathComponent("3-review-undecided.png"))
        model.keep(fileAt: 0)
        model.previous()
        model.focusedPath = model.currentReviewGroup?.files[1].path
        try await render(model, to: out.appendingPathComponent("4-review-chosen.png"))

        model.confirmingTrash = true
        try await render(ConfirmTrashSheet().environment(model), size: CGSize(width: 520, height: 300),
                         to: out.appendingPathComponent("5-confirm.png"))
        model.confirmingTrash = false

        model.tab = .problems
        try await render(model, to: out.appendingPathComponent("6-problems.png"))

        photos.isolate(model)
        model.tab = .suggested
        model.startClean()
        for _ in 0..<100 where model.stage != .summary { try await Task.sleep(for: .milliseconds(50)) }
        try await render(model, to: out.appendingPathComponent("7-summary.png"))
    }

    private func render(_ model: AppModel, to url: URL) async throws {
        try await render(ContentView().environment(model), size: CGSize(width: 1100, height: 720), to: url)
    }

    private func render(_ view: some View, size: CGSize, to url: URL) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        // Let SwiftUI lay out and the thumbnail/capture-date tasks finish.
        for _ in 0..<15 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        window.close()
    }
}
