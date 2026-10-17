import AppKit
import DoppioCore
import SwiftUI

@main
struct DoppioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("Doppio", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { delegate.model = model }
        }
        .commands { DoppioCommands(model: model) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run straight from `swift run` (outside the .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Never quit in the middle of moving a file: stop after the current one, then quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isChangingFiles else { return .terminateNow }
        model.stopForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct DoppioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Scan") { model.newScan() }
                .keyboardShortcut("n")
                .disabled(model.isBusy || model.stage == .setup)
            Button("Export Audit Report…") { model.exportRequested = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.result == nil || model.isBusy)
        }
        // Shortcuts without modifiers are only enabled while reviewing, so they never
        // swallow keys elsewhere.
        CommandMenu("Review") {
            let reviewing = model.canUseReviewKeys
            let fileCount = model.currentReviewGroup?.files.count ?? 0
            ForEach(1...9, id: \.self) { n in
                Button("Keep File \(n)") { model.keep(fileAt: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: [])
                    .disabled(!reviewing || fileCount < n)
            }
            Divider()
            Button("Keep All Files in This Group") { model.keepAll() }
                .keyboardShortcut("k", modifiers: [])
                .disabled(!reviewing)
            Button("Next Group") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!reviewing)
            Button("Previous Group") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!reviewing)
            Divider()
            Button("Quick Look") { model.toggleQuickLook() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.stage != .results || model.confirmingTrash
                          || (model.focusedPath == nil && !reviewing && model.previewURL == nil))
            Button("Reveal in Finder") { if let path = model.focusedPath { model.reveal(path) } }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.focusedPath == nil)
        }
    }
}
