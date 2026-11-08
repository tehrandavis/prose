import AppKit
@testable import ProseApp
import ProseCore
import PDFKit
import Testing

extension WritingFlowTests {
    @Test func libraryIncludeCompilesOriginalChapterWithItsModulesAndImages() async throws {
        let app = try WritingFixture(text: "External draft", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        let book = try await library.store.create(title: "Book", text: "= Book\n\n")
        let project = app.root.appendingPathComponent("Chapter project")
        for directory in ["modules", "sections", "images"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(directory), withIntermediateDirectories: true,
            )
        }
        let chapterText = """
        #import "modules/label.typ": chapter-name
        = #chapter-name
        #include "sections/body.typ"
        """
        let entry = project.appendingPathComponent("chapter.typ")
        try Data(chapterText.utf8).write(to: entry)
        try Data("#let chapter-name = [Original chapter]".utf8)
            .write(to: project.appendingPathComponent("modules/label.typ"))
        try Data("Nested body\n#image(\"../images/diagram.svg\", width: 20pt)".utf8)
            .write(to: project.appendingPathComponent("sections/body.typ"))
        let svg = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><circle cx=\"10\" cy=\"10\" r=\"8\"/></svg>"
                .utf8,
        )
        try svg.write(to: project.appendingPathComponent("images/diagram.svg"))
        let chapter = try await library.store.importProject(at: project, mainFile: entry, title: "Chapter")
        let trashed = try await library.store.create(title: "Old chapter", text: "Old")
        _ = try await library.store.trash(trashed.id)
        await library.refresh()
        try await library.open(book.id)
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let include = try #require(WritingCommand.all.first { $0.id == "include" })
        app.workspace.togglePalette()
        app.workspace.selectCommand(include)
        try await app.wait { !app.workspace.availableLibraryDocuments.isEmpty }
        #expect(app.workspace.availableLibraryDocuments.map(\.id) == [chapter.id])
        app.workspace.resourceSelection = .libraryDocument(chapter)
        app.workspace.execute(include)
        try await app.wait { !app.workspace.applyingCommand }
        try #require(!app.workspace.paletteOpen, "Command error: \(app.workspace.commandError ?? "none")")
        let reference = "../\(chapter.id.uuidString)/Project/chapter.typ"
        #expect(editor.string.contains("#include \"\(reference)\""))
        #expect(!editor.string.contains(app.root.path))
        #expect(!FileManager.default.fileExists(atPath: book.folderURL.appendingPathComponent("assets").path))
        editor.undoManager?.undo()
        #expect(editor.string == "= Book\n\n")
        editor.undoManager?.redo()
        let pdf = app.root.appendingPathComponent("book.pdf")
        try await app.workspace.exportPDF(to: pdf)
        let contents = try #require(PDFDocument(url: pdf)?.string)
        #expect(contents.contains("Book"))
        #expect(contents.contains("Original chapter"))
        #expect(contents.contains("Nested body"))

        _ = try await library.store.rename(chapter.id, title: "Renamed chapter")
        await library.refresh()
        try #require(app.workspace.open(chapter.sourceURL, preservingMain: true))
        try await app.ready()
        #expect(app.workspace.compilationURL == book.sourceURL)
        editor.insertSnippet(
            Snippet(text: chapterText + "\nLatest chapter edit\n"),
            replacing: NSRange(location: 0, length: editor.string.utf16.count),
        )
        let image = app.root.appendingPathComponent("new-diagram.svg")
        try svg.write(to: image)
        let range = NSRange(location: editor.string.utf16.count, length: 0)
        editor.setSelectedRange(range)
        try await app.workspace.importAndInsertResources([.file(image)], kind: .image, replacing: range)
        #expect(editor.string.contains("image(\"assets/"))
        #expect(FileManager.default.fileExists(atPath: chapter.sourceURL.deletingLastPathComponent()
                .appendingPathComponent("assets").path))
        #expect(!FileManager.default.fileExists(atPath: book.folderURL.appendingPathComponent("assets").path))
        app.workspace.save()
        try await app.workspace.exportPDF(to: pdf)
        #expect(try #require(PDFDocument(url: pdf)?.string).contains("Latest chapter edit"))
        #expect(try String(contentsOf: book.sourceURL, encoding: .utf8).contains(reference))
    }

    @Test func libraryImportCompilesSharedDefinitionsAndRejectsTrashedSelections() async throws {
        let app = try WritingFixture(text: "External draft", startService: false)
        defer { app.close() }
        let library = app.workspace.library
        let book = try await library.store.create(title: "Book", text: "#shared-label\n")
        let module = try await library.store.create(
            title: "Shared definitions",
            text: "#let shared-label = [Shared text]",
        )
        await library.refresh()
        try await library.open(book.id)
        try await app.ready()
        let command = try #require(WritingCommand.all.first { $0.id == "import" })
        app.workspace.togglePalette()
        app.workspace.selectCommand(command)
        try await app.wait { !app.workspace.availableLibraryDocuments.isEmpty }
        app.workspace.resourceSelection = .libraryDocument(module)
        app.workspace.execute(command)
        try await app.wait { !app.workspace.applyingCommand }
        try #require(!app.workspace.paletteOpen, "Command error: \(app.workspace.commandError ?? "none")")
        let editor = try #require(app.workspace.editor)
        #expect(editor.string.hasPrefix("#import \"../\(module.id.uuidString)/main.typ\": *"))
        let pdf = app.root.appendingPathComponent("shared.pdf")
        try await app.workspace.exportPDF(to: pdf)
        #expect(try #require(PDFDocument(url: pdf)?.string).contains("Shared text"))

        app.workspace.togglePalette()
        app.workspace.selectCommand(command)
        try await app.wait { !app.workspace.availableLibraryDocuments.isEmpty }
        let image = try #require(WritingCommand.all.first { $0.id == "image" })
        app.workspace.selectCommand(image)
        #expect(app.workspace.availableLibraryDocuments.isEmpty)
        app.workspace.selectCommand(command)
        try await app.wait { !app.workspace.availableLibraryDocuments.isEmpty }
        app.workspace.resourceSelection = .libraryDocument(module)
        _ = try await library.store.trash(module.id)
        let original = editor.string
        app.workspace.execute(command)
        try await app.wait { !app.workspace.applyingCommand }
        #expect(app.workspace.commandError == DocumentResourceError.invalidLocation.localizedDescription)
        #expect(editor.string == original)
        app.workspace.closePalette()
    }
}
