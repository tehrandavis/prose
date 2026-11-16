import AppKit
@testable import ProseApp
import ProseCore
import Testing

/// What launch shows (Phase 7, decisions 1 and 3). Each workspace is built
/// with `Workspace.launching` and started with `launch()`, the path the app
/// delegate takes.
extension WritingFlowTests {
    /// Acceptance test 11.
    @Test func launchOpensABlankPageUnlessWorkIsUnsaved() async throws {
        let saved = "= Saved\n"
        let app = try WritingFixture(text: saved, startService: false, launching: true)
        defer { app.close() }
        let state = app.workspace.stateDirectory
        try keepLibraryLocal(in: state)
        #expect(LaunchPreference.value(in: app.defaults) == .blankPage, "Blank page is the default")

        // A saved last document: the window waits with an empty page that
        // cannot be typed in, never the document or the home list.
        let workspace = app.workspace
        #expect(workspace.launchPending)
        #expect(!workspace.isLibraryHome)
        #expect(workspace.fileURL == nil && workspace.text.isEmpty)
        #expect(!workspace.canEditSource)
        await app.layout()
        #expect(app.workspace.editor?.isEditable == false)
        await workspace.launch()
        let page = try #require(workspace.library.blankPageID)
        #expect(workspace.managedDocumentID == page)
        #expect(!workspace.launchPending && !workspace.isLibraryHome)
        #expect(workspace.text == DocumentTemplate.blank.source)
        #expect(workspace.editorMode == .writing)
        #expect(workspace.editor?.isEditable == true)
        #expect(workspace.discoveryMode == nil && !workspace.libraryOpen)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == saved)
        let log = try String(contentsOf: state.appendingPathComponent("Logs/events.jsonl"), encoding: .utf8)
        #expect(log.contains("launch.ready"))

        // A session that ended on the untouched blank page reopens the same
        // page at once, with no wait and no second document.
        #expect(workspace.prepareToClose())
        workspace.library.stop()
        let again = Workspace.launching(stateDirectory: state, defaults: app.defaults)
        #expect(!again.launchPending)
        #expect(again.fileURL == workspace.fileURL)
        #expect(again.text == DocumentTemplate.blank.source)
        #expect(again.editorMode == .writing)
        #expect(again.selection == NSRange(location: DocumentTemplate.blank.source.utf16.count, length: 0))
        await again.launch()
        #expect(again.managedDocumentID == page)
        #expect(again.library.blankPageID == page)
        #expect(try await again.library.store.list(includeTrashed: true).map(\.id) == [page])
        again.shutdown()

        // Unsaved text: that document, with the text.
        let unsavedState = app.root.appendingPathComponent("Unsaved")
        try writeSnapshot(
            RecoverySnapshot(fileURL: app.document, text: saved + "Not saved yet.\n", savedText: saved, selection: 0),
            in: unsavedState,
        )
        let unsaved = Workspace.launching(stateDirectory: unsavedState, defaults: app.defaults)
        #expect(!unsaved.launchPending)
        #expect(unsaved.fileURL == app.document)
        #expect(unsaved.text == saved + "Not saved yet.\n")
        #expect(unsaved.saveStatus == "Unsaved Work Restored")
        await unsaved.launch()
        #expect(unsaved.fileURL == app.document)
        #expect(unsaved.text == saved + "Not saved yet.\n")
        #expect(unsaved.library.blankPageID == nil)
        unsaved.shutdown()

        // The setting on "Last document": the last document. The Settings
        // picker writes this Mac's defaults.
        workspace.launchPage = .lastDocument
        #expect(LaunchPreference.value(in: app.defaults) == .lastDocument)
        let lastState = app.root.appendingPathComponent("Last")
        try writeSnapshot(
            RecoverySnapshot(fileURL: app.document, text: saved, savedText: saved, selection: 0),
            in: lastState,
        )
        let last = Workspace.launching(stateDirectory: lastState, defaults: app.defaults)
        #expect(!last.launchPending)
        #expect(last.fileURL == app.document && last.text == saved)
        await last.launch()
        #expect(last.fileURL == app.document)
        #expect(last.library.blankPageID == nil)
        last.shutdown()

        // A snapshot of the home state leads to a blank page with either setting.
        let homeState = app.root.appendingPathComponent("Home")
        try writeSnapshot(
            RecoverySnapshot(fileURL: nil, text: "", savedText: "", selection: 0, libraryHome: true),
            in: homeState,
        )
        let home = Workspace.launching(stateDirectory: homeState, defaults: app.defaults)
        #expect(home.launchPending && !home.isLibraryHome)
        await home.launch()
        #expect(!home.isLibraryHome)
        #expect(home.library.blankPageID != nil && home.managedDocumentID == home.library.blankPageID)
        home.shutdown()
        LaunchPreference.set(.blankPage, in: app.defaults)

        // No snapshot: the first launch opens the Welcome guide, adopted into
        // the library, and makes no blank page.
        let freshState = app.root.appendingPathComponent("Fresh")
        try keepLibraryLocal(in: freshState)
        let fresh = Workspace.launching(stateDirectory: freshState, defaults: app.defaults)
        #expect(!fresh.launchPending)
        #expect(fresh.text == WelcomeDocument.source())
        #expect(fresh.layout == .split)
        await fresh.launch()
        try await app.wait { fresh.managedDocumentID != nil }
        #expect(fresh.managedTitle == L10n.text("Welcome"))
        #expect(fresh.library.blankPageID == nil)
        #expect(try await fresh.library.store.list().map(\.title) == [L10n.text("Welcome")])
        fresh.shutdown()

        // A file opened from Finder while launch waits opens that file.
        let finderState = app.root.appendingPathComponent("Finder")
        try writeSnapshot(
            RecoverySnapshot(fileURL: app.document, text: saved, savedText: saved, selection: 0),
            in: finderState,
        )
        let other = app.root.appendingPathComponent("other.typ")
        try Data("= From Finder\n".utf8).write(to: other)
        let finder = Workspace.launching(stateDirectory: finderState, defaults: app.defaults)
        let delegate = AppDelegate(workspace: finder)
        delegate.application(NSApp, openFiles: [other.path])
        #expect(!finder.launchPending)
        await finder.launch()
        #expect(finder.fileURL == other)
        #expect(finder.text == "= From Finder\n")
        #expect(finder.library.blankPageID == nil)
        finder.shutdown()
    }

    /// Acceptance test 12. The library cannot make a document (its folder is
    /// read-only): launch shows the home state in place with the error and
    /// no gallery, and the close button and `⌘W` quit.
    @Test func aLibraryThatCannotMakeABlankPageShowsTheListInPlace() async throws {
        let app = try WritingFixture(text: "= Saved\n", startService: false, launching: true)
        defer { app.close() }
        let state = app.workspace.stateDirectory
        try keepLibraryLocal(in: state)
        let documents = state.appendingPathComponent("Library/Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: documents.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path) }
        let delegate = AppDelegate(workspace: app.workspace)
        var terminations = 0
        delegate.terminateApplication = { terminations += 1 }
        delegate.keyWindow = { app.window }
        let guardian = TerminationGuard()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = guardian
        app.window.delegate = delegate
        defer { app.window.delegate = nil
            NSApp.delegate = previousDelegate
        }
        app.window.orderFront(nil)

        await app.workspace.launch()
        await app.layout()
        #expect(app.workspace.isLibraryHome)
        #expect(!app.workspace.launchPending)
        #expect(app.workspace.library.blankPageID == nil)
        #expect(app.workspace.library.error != nil)
        #expect(app.workspace.message != nil)
        #expect(app.workspace.discoveryMode == nil, "The gallery does not open by itself")
        #expect(!app.workspace.libraryOpen && app.window.attachedSheet == nil, "The list is in place, not a sheet")
        #expect(try await app.workspace.library.store.list(includeTrashed: true).isEmpty)
        #expect(try String(contentsOf: app.document, encoding: .utf8) == "= Saved\n")

        #expect(!delegate.windowShouldClose(app.window))
        #expect(terminations == 1)
        delegate.closeFront(nil)
        #expect(terminations == 2)
        #expect(guardian.requests == 0)
    }
}

/// A library that stays on this Mac, so `LibraryController.start()` does not
/// try to turn on iCloud.
private func keepLibraryLocal(in state: URL) throws {
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data("local".utf8).write(to: state.appendingPathComponent("library-location.json"))
}

private func writeSnapshot(_ snapshot: RecoverySnapshot, in state: URL) throws {
    try keepLibraryLocal(in: state)
    try JSONEncoder().encode(snapshot).write(to: state.appendingPathComponent("recovery.json"))
}
