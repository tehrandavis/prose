import AppKit
import Foundation
@testable import ProseApp
import ProseCore
import Testing

/// A file in a folder opened in place follows a change another program makes
/// to it on disk (2026-11-17). Not run when it was written: Tehran asked for
/// no window-opening test runs for now. It is owed to the later check pass.
extension WritingFlowTests {
    @Test func anOpenProjectFileFollowsAnOutsideEditAndKeepsLocalEdits() async throws {
        let app = try WritingFixture(text: "= Loose file\n", startService: false)
        defer { app.close() }
        let root = app.root.appendingPathComponent("Paper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("main.typ")
        let base = "= Paper\n\nFirst paragraph\n\nSecond paragraph\n"
        try Data(base.utf8).write(to: main, options: .atomic)
        #expect(app.workspace.openFolder(root))
        let editor = try #require(app.workspace.editor)
        #expect(app.workspace.managedDocumentID == nil)
        #expect(editor.string == base)

        // A clean buffer takes the outside version whole, through the watcher.
        let agent = base.replacingOccurrences(of: "First", with: "The agent's first")
        try Data(agent.utf8).write(to: main, options: .atomic)
        try await app.wait { editor.string == agent }
        #expect(app.workspace.savedText == agent)
        #expect(app.workspace.saveStatus == "Saved")

        // An unsaved edit in another paragraph is kept, and the save then works.
        editor.insertSnippet(Snippet(text: "My second"), replacing: (editor.string as NSString).range(of: "Second"))
        let outside = agent.replacingOccurrences(of: "= Paper", with: "= Paper, revised")
        try Data(outside.utf8).write(to: main, options: .atomic)
        try await app.wait { editor.string.contains("= Paper, revised") }
        #expect(editor.string.contains("My second"))
        app.workspace.save()
        #expect(app.workspace.saveStatus == "Saved")
        #expect(try String(contentsOf: main, encoding: .utf8) == editor.string)

        // Prose's own save changes nothing: the disk equals the saved text.
        let saved = editor.string
        app.workspace.openFileChangedOnDisk(among: [main])
        await app.workspace.refreshFromDisk()
        #expect(editor.string == saved)
    }
}
