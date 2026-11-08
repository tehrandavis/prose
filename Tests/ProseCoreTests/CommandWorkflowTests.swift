#if os(macOS)
    import AppKit
#else
    @testable import ProseTablet
    import UIKit
#endif
import Foundation
import PDFKit
@testable import ProseCore
import ProseTestSupport
import Testing

@MainActor
#if os(macOS)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PROSE_INTEGRATION"] == "1"))
#else
    @Test
#endif
func everyDiscoveredInsertionProducesARealDocument() async throws {
    let root = TestPaths.temporaryDirectory.appendingPathComponent("Prose-command-workflow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("images"),
        withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: root) }
    #if os(macOS)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        ))
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("images/figure.png"))
    #else
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try image.write(to: root.appendingPathComponent("images/figure.png"))
    #endif
    try Data("Included fixture".utf8).write(to: root.appendingPathComponent("section.typ"))
    try Data("#let catalog-helper = \"Reusable fixture\"".utf8).write(to: root.appendingPathComponent("helpers.typ"))
    try Data("@book{example, title={Catalog Reference}, author={Doe, Jane}, date={2024}}".utf8)
        .write(to: root.appendingPathComponent("references.bib"))
    let file = root.appendingPathComponent("workflow.typ")
    try Data("Saved baseline".utf8).write(to: file)
    #if os(macOS)
        let client = TinymistClient()
    #else
        let client = TinymistClient(makeTransport: { EmbeddedTinymist() })
    #endif
    defer { client.stop() }
    try await client.start(root: root, outputDirectory: root)
    try client.open(file, text: "Saved baseline", version: 1)
    _ = try await client.startPreview(file)

    var version = 1
    for command in WritingCommand.all where command.isInsertion {
        version += 1
        let values = command.id == "label" ? ["name": "another-label"] : [:]
        let snippet = try TypstInsertion.make(command.id, values: values)
        let baseline = "#set text(font: (\"Libertinus Serif\", \"PingFang SC\"))\n#set heading(numbering: \"1.\")\n= Target <section-intro>\n\nBefore sentinel\n\nAfter sentinel\n"
        let offset = (baseline as NSString).range(of: "After sentinel").location
        let plan = InsertionPlan(
            command: command,
            snippet: snippet,
            text: baseline,
            selection: NSRange(location: offset, length: 0),
        )
        var document = (baseline as NSString).replacingCharacters(in: plan.range, with: plan.snippet.text + "\n\n")
        if command.id == "citation" {
            document += "\n#bibliography(\"references.bib\")\n"
        }
        if command.id == "bibliography" {
            document += "\n#cite(<example>)\n"
        }
        if command.id == "import" {
            document += "\n#catalog-helper\n"
        }
        if command.id == "variable" {
            document += "\n#project\n"
        }
        try client.change(file, text: document, version: version)
        do {
            let result = try await client.command("tinymist.exportPdf", arguments: [file.path])
            let pdfPath = try #require(result["path"].string)
            let rendered = try #require(PDFDocument(url: URL(fileURLWithPath: pdfPath))?.string)
            #expect(rendered.contains("Before sentinel"), "\(command.id) preserves preceding content")
            #expect(rendered.contains("After sentinel"), "\(command.id) preserves following content")
            if command.id == "include" {
                #expect(rendered.contains("Included fixture"))
            }
            if command.id == "import" {
                #expect(rendered.contains("Reusable fixture"))
            }
            if command.id == "citation" || command
                .id == "bibliography"
            {
                #expect(rendered.contains("Catalog Reference"))
            }
            #expect(try String(contentsOf: file, encoding: .utf8) == "Saved baseline", "Preview uses the unsaved edit")
        } catch {
            Issue.record("\(command.id) failed to compile: \(error.localizedDescription)\n\(document)")
        }
    }

    // Every formula helper must also work inside an already-open equation.
    for command in WritingCommand.all where command.supportsMath {
        version += 1
        let snippet = try TypstInsertion.make(command.id, context: .math)
        #expect(!snippet.text.contains("$"), "\(command.id) must not nest formula delimiters")
        try client.change(file, text: "Formula sentinel\n\n$ \(snippet.text) $", version: version)
        do {
            let result = try await client.command("tinymist.exportPdf", arguments: [file.path])
            let path = try #require(result["path"].string)
            #expect(PDFDocument(url: URL(fileURLWithPath: path))?.string?.contains("Formula sentinel") == true)
        } catch { Issue.record("Math context for \(command.id) failed: \(error.localizedDescription)") }
    }
}

@Test func discoveryConnectsSearchGroupsExamplesAndSafeParameters() throws {
    #expect(WritingCommand.all.filter(\.isInsertion).count >= 60)
    #expect(Set(WritingCommand.all.map(\.id)).count == WritingCommand.all.count)
    for parent in [nil] + CommandGroup.all.map({ Optional($0.id) }) {
        let groups = CommandGroup.children(of: parent)
        let commands = WritingCommand.all.filter { $0.group == parent }
        let keys = groups.map(\.key) + commands.map(\.key)
        #expect(Set(keys).count == keys.count, "Ambiguous discovery path: \(parent ?? "root")")
    }
    for command in WritingCommand.all {
        #expect(CommandGroup.all.contains { $0.id == command.group })
        if command.isInsertion {
            #expect(command.documentationURL?.host == "typst.app")
            #expect(command.example?.isEmpty == false)
            #expect(command.acceptsContext("markup"))
            #expect(command.acceptsContext("math") == command.supportsMath)
            #expect(!command.acceptsContext("raw"))
            #expect(!command.acceptsContext("code"))
            #expect(!command.acceptsContext("comment"))
        } else {
            #expect(command.example == nil)
            #expect(command.documentationURL == nil)
        }
    }
    #expect(WritingCommand.search("分数").contains { $0.id == "fraction" })
    #expect(WritingCommand.search("matrix").contains { $0.id == "matrix" })
    #expect(WritingCommand.search("首行 缩进").contains { $0.id == "firstLineIndent" })
    #expect(WritingCommand.search("插件").contains { $0.id == "universe" })
    #expect(CommandGroup.roots.count <= 10)

    for (id, fields) in [
        ("textColor", ["color": "red); panic(\"oops\")"]),
        ("language", ["language": "zh-CN"]),
        ("leading", ["amount": "NaN"]),
        ("paragraphSpacing", ["amount": "-1"]),
        ("firstLineIndent", ["amount": "21"]),
        ("align", ["alignment": "center + panic()"]),
        ("columns", ["columns": "10"]),
        ("variable", ["name": "for"]),
        ("citation", ["name": "x> #panic()"]),
    ] {
        #expect(throws: CommandError.self) { try TypstInsertion.make(id, values: fields) }
    }

    let literal = "\"«中文😀»\\\n"
    for id in ["font", "header", "footer", "documentInfo", "include", "import", "variable", "rawInline"] {
        let snippet = try TypstInsertion.make(
            id,
            values: ["font": literal, "text": literal, "title": literal, "author": literal, "path": literal,
                     "value": literal],
            selection: literal,
        )
        #expect(snippet.selections.isEmpty, "Literal guillemets must not create placeholders: \(id)")
        #expect(snippet.text.contains("«中文😀»"))
    }
}
