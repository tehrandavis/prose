import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import SwiftUI
import Testing

extension WritingFlowTests {
    @Test func historyPresentationRendersEmptyChangesAndMatchingSnapshot() async throws {
        let app = try WritingFixture(text: "= Draft\n\nA quiet place. 中文 😀\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace, history = workspace.history
        let host = NSHostingView(rootView: DocumentHistoryView(workspace: workspace, history: history))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        placeOnTestScreen(window)
        window.contentView = host
        defer { window.close() }
        func draw() async throws -> Data {
            host.layoutSubtreeIfNeeded()
            await app.layout()
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize == NSSize(width: 940, height: 600))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let empty = try await draw()
        #expect(history.revisions.isEmpty)
        let original = try await history.store.preserveBeforeRestore(
            "= Draft\n\nA busy place. 中文 😀\n",
            key: workspace.historyKey,
            at: Date(),
        )
        await history.load()
        await history.select(original)
        let changes = try await draw()
        #expect(changes != empty, "The history window must render its comparison, even without a visible sheet")
        let comparison = try #require(history.comparison)
        #expect(!comparison.addedRanges.isEmpty && !comparison.removedRanges.isEmpty)
        #expect(await history.restore(original))
        await history.load()
        await history.select(original)
        let matching = try await draw()
        #expect(history.comparison?.identical == true)
        #expect(matching != changes, "Restoration must replace the comparison with the matching-snapshot state")
    }

    @Test func editedHistorySurvivesAutosaveSwitchAndRestoresWithUndo() async throws {
        let app = try WritingFixture(text: "= Original\n\nFirst words.\n", startService: false)
        defer { app.close() }
        let workspace = app.workspace, history = app.workspace.history
        let editor = try #require(workspace.editor)
        var date = Date(timeIntervalSince1970: 1_000_000)
        history.now = { date }
        let key = workspace.historyKey
        #expect(try await history.store.revisions(for: key).isEmpty)
        // Reading/saving an unchanged document never creates history.
        workspace.save()
        await history.drain()
        #expect(try await history.store.revisions(for: key).isEmpty)
        editor.insertSnippet(
            Snippet(text: "More writing.\n"),
            replacing: NSRange(location: workspace.text.utf16.count, length: 0),
        )
        try await app.wait { workspace.text == workspace.savedText }
        await history.drain()
        var revisions = try await history.store.revisions(for: key)
        #expect(revisions.count == 1)
        let original = try #require(revisions.first)
        #expect(try await history.store.source(for: original, key: key) == "= Original\n\nFirst words.\n")
        let second = workspace.text
        date = date.addingTimeInterval(3601)
        editor.insertSnippet(
            Snippet(text: "A later thought.\n"),
            replacing: NSRange(location: workspace.text.utf16.count, length: 0),
        )
        workspace.save()
        await history.drain()
        revisions = try await history.store.revisions(for: key)
        #expect(revisions.count == 2)
        #expect(try await history.store.source(for: revisions[0], key: key) == second)
        let current = workspace.text
        let historyCommand = try #require(WritingCommand.all.first { $0.id == "history" })
        workspace.execute(historyCommand)
        #expect(workspace.historyOpen)
        // Opening the real sheet starts its .task. Wait for that presentation
        // instead of launching a second load that races the sheet's first one.
        try await app.wait { !history.busy && history.comparison != nil && history.revisions.count == 2 }
        await history.select(original)
        await app.layout()
        #expect(history.selectedID == original.id)
        #expect(history.comparison?.identical == false)
        #expect(history.comparison?.after.contains("A later thought") == true)
        let comparison = try #require(history.comparison)
        #expect(comparison.removedRanges.isEmpty)
        #expect(comparison.addedRanges.map { (comparison.after as NSString).substring(with: $0) }.joined()
            .contains("More writing."))
        #expect(await history.restore(original))
        #expect(workspace.text == "= Original\n\nFirst words.\n")
        revisions = try await history.store.revisions(for: key)
        #expect(revisions[0].reason == .beforeRestore)
        #expect(try await history.store.source(for: revisions[0], key: key) == current)
        editor.undoManager?.undo()
        #expect(workspace.text == current)
        let other = app.root.appendingPathComponent("other.typ")
        try Data("Another document".utf8).write(to: other)
        #expect(workspace.open(other))
        #expect(workspace.historyKey != key)
        await history.load()
        #expect(history.revisions.isEmpty)
        #expect(workspace.open(app.document))
        await history.load()
        #expect(history.revisions.count == 3)
        #expect(workspace.text == current)
    }

    @Test func historyFailureKeepsWritingAndRefusesUnsafeRestore() async throws {
        let app = try WritingFixture(text: "Important writing", startService: false)
        defer { app.close() }
        let workspace = app.workspace, history = app.workspace.history
        let editor = try #require(workspace.editor)
        let root = workspace.stateDirectory.appendingPathComponent("History")
        try Data("block history directory".utf8).write(to: root)
        editor.insertSnippet(
            Snippet(text: " plus more"),
            replacing: NSRange(location: workspace.text.utf16.count, length: 0),
        )
        workspace.save()
        await history.drain()
        #expect(workspace.savedText == "Important writing plus more")
        #expect(history.error != nil)
        try FileManager.default.removeItem(at: root)
        let revision = try await history.store.preserveBeforeRestore("Original", key: workspace.historyKey, at: Date())
        let folder = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first)
        // Existing snapshots stay readable, but preserving current writing fails.
        // Restore must leave the live buffer and disk untouched in that case.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(await !(history.restore(revision)))
        #expect(workspace.text == "Important writing plus more")
        #expect(workspace.savedText == "Important writing plus more")
        #expect(history.error != nil)
        #expect(try await history.store.revisions(for: workspace.historyKey).count == 1)
    }

    @Test func quittingImmediatelyAfterEditingFinishesTheCheckpoint() async throws {
        let app = try WritingFixture(text: "Before quit", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let editor = try #require(workspace.editor)
        let delegate = AppDelegate(workspace: workspace)
        var approved = false
        // Exercise native termination sequencing without exiting the test host.
        delegate.replyToTermination = { approved = $0 }
        editor.insertSnippet(
            Snippet(text: " after"),
            replacing: NSRange(location: workspace.text.utf16.count, length: 0),
        )
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        #expect(!approved)
        try await app.wait { approved }
        let revisions = try await workspace.history.store.revisions(for: workspace.historyKey)
        #expect(revisions.count == 1)
        #expect(try await workspace.history.store.source(for: revisions[0], key: workspace.historyKey) == "Before quit")
        #expect(workspace.savedText == "Before quit after")
    }

    @Test func managedHistoryIdentityAndIntervalPreferencesAreStable() async throws {
        let app = try WritingFixture(text: "Original", startService: false)
        defer { app.close() }
        let workspace = app.workspace
        let id = UUID()
        workspace.managedDocumentID = id
        workspace.managedTitle = "A title"
        let key = workspace.historyKey
        workspace.managedTitle = "A new title"
        #expect(workspace.historyKey == key)
        workspace.mainFileURL = app.document
        workspace.fileURL = app.document.deletingLastPathComponent().appendingPathComponent("styles/layout.typ")
        #expect(workspace.historyKey == "library:\(id)/styles/layout.typ")
        let defaults = try #require(UserDefaults(suiteName: "Prose-history-\(UUID())"))
        let settings = WorkspaceSettings(workspace: workspace, defaults: defaults)
        defer { settings.stop() }
        workspace.historyInterval = .daily
        try await app.wait { settings.preferences.values.historyInterval == "daily" }
        #expect(LibraryPreferences(defaults: defaults).values.historyInterval == "daily")
        #expect(HistoryInterval.daily.duration == 86400)
    }
}
