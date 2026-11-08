import AppKit
@testable import ProseApp
import ProseCore
import SwiftUI
import Testing

extension WritingFlowTests {
    @Test func contextualHelpActionsUndoAndStaleResponsesUseLiveSource() async throws {
        let source = "#rect(width: 20pt, height: 30pt)\n== Heading\n$alpha+beta$\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "quickHelp" }))
        try await app.wait { app.workspace.assistance != nil }
        #expect(app.workspace.assistance?.hover?.text.lowercased().contains("rectangle") == true)
        #expect(editor.assistancePopover?.contentSize.width ?? 999 <= 420)
        #expect(editor.string == source)
        app.workspace.dismissAssistance()
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        app.workspace.requestAssistance(.help)
        try await app.wait { app.workspace.assistance?.signature != nil }
        #expect(app.workspace.assistance?.signature?.activeParameter == "width:")
        app.workspace.dismissAssistance()
        let heading = (source as NSString).range(of: "Heading")
        editor.setSelectedRange(NSRange(location: heading.location, length: 0))
        app.workspace.requestAssistance(.actions)
        try await app.wait { app.workspace.assistance?.actions.isEmpty == false }
        let action = try #require(app.workspace.assistance?.actions.first { $0.title == "Increase depth of heading" })
        app.workspace.applyContextAction(action)
        #expect(editor.string.contains("=== Heading"))
        #expect(app.workspace.text == editor.string)
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        editor.undoManager?.redo()
        #expect(app.workspace.text.contains("=== Heading"))
        editor.undoManager?.undo()
        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        editor.insertSnippet(Snippet(text: "More"), replacing: editor.selectedRange())
        let newer = editor.string
        app.workspace.applyContextAction(action)
        #expect(editor.string == newer, "An action from an older revision cannot overwrite typing")
        editor.setSelectedRange(NSRange(location: heading.location, length: 0))
        app.workspace.requestAssistance(.actions)
        editor.insertSnippet(Snippet(text: "New "), replacing: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(250))
        #expect(app.workspace.assistance == nil, "A response arriving after typing must not reopen assistance")
        #expect(editor.string == app.workspace.text)
    }

    @Test func definitionAndBackKeepTheWritersPlaceAcrossFiles() async throws {
        let source = "#let greeting = [Hello]\n\n#greeting\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let origin = (source as NSString).range(of: "#greeting").location + 3
        editor.setSelectedRange(NSRange(location: origin, length: 0))
        app.workspace.goToDefinition()
        try await app.wait { app.workspace.position.line == 0 }
        app.workspace.navigateBack()
        #expect(app.workspace.selection.location == origin)
        let module = app.root.appendingPathComponent("module.typ")
        try Data("#let greeting = [Imported]\n".utf8).write(to: module)
        let imports = "#import \"module.typ\": greeting\n#greeting\n"
        editor.insertSnippet(Snippet(text: imports), replacing: NSRange(location: 0, length: editor.string.utf16.count))
        let importedOrigin = (imports as NSString).range(of: "#greeting").location + 3
        editor.setSelectedRange(NSRange(location: importedOrigin, length: 0))
        app.workspace.goToDefinition()
        try await app.wait { app.workspace.documentURL == module }
        #expect(app.workspace.compilationURL == app.document)
        app.workspace.navigateBack()
        #expect(app.workspace.documentURL == app.document)
        #expect(app.workspace.selection.location == importedOrigin)
        #expect(app.workspace.text == imports)
    }

    @Test func checksFloatWithoutMovingTextAndRecoverFromErrors() async throws {
        let source = "= Calm writing\n\nBody\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        try await app.wait { app.workspace.checksPassed }
        let editor = try #require(app.workspace.editor)
        let scroll = try #require(editor.enclosingScrollView)
        let originalFrame = scroll.convert(scroll.bounds, to: nil)
        let originalInset = editor.textContainerInset
        app.workspace.checksOpen = true
        await app.layout()
        #expect(scroll.convert(scroll.bounds, to: nil) == originalFrame)
        #expect(editor.textContainerInset == originalInset)
        #expect(app.workspace.checkIcon == "check")
        let diagnostic = try #require(WritingCommand.all.first { $0.id == "diagnostics" })
        app.workspace.execute(diagnostic)
        #expect(!app.workspace.checksOpen)
        editor.insertSnippet(
            Snippet(text: "#unknown-function()"),
            replacing: NSRange(location: editor.string.utf16.count, length: 0),
        )
        #expect(!app.workspace.checksPassed)
        try await app.wait { app.workspace.checkErrors > 0 }
        app.workspace.checksOpen = true
        await app.layout()
        #expect(scroll.convert(scroll.bounds, to: nil) == originalFrame)
        #expect(app.workspace.checkIcon == "warning-circle")
        let issue = try #require(app.workspace.diagnostics.first)
        app.workspace.showDiagnostic(issue)
        #expect(!app.workspace.checksOpen)
        #expect(app.workspace.selection.location == issue.position.offset(in: editor.string))
        editor.undoManager?.undo()
        try await app.wait { app.workspace.checksPassed }
        app.workspace.checksOpen = true
        app.window.sendEvent(app.key("\u{1b}", code: 53))
        #expect(!app.workspace.checksOpen)
        #expect(editor.string == source)
        app.workspace.serviceReady = false
        #expect(!app.workspace.checksPassed)
        #expect(app.workspace.checkIcon == "plugs-connected")
    }
}
